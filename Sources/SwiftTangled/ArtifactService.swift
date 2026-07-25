import Crypto
import Foundation
import SwiftAtproto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct ArtifactService: Sendable {
  private let bobbinClient: BobbinClient
  private let repositoryLocator: RepositoryLocator
  private let resolver: any ATPResolver
  private let transport: any HTTPTransport

  public init(
    bobbinClient: BobbinClient = BobbinClient(),
    repositoryLocator: RepositoryLocator? = nil,
    resolver: any ATPResolver = URLSessionATPResolver(),
    transport: any HTTPTransport = URLSessionTransport()
  ) {
    self.bobbinClient = bobbinClient
    self.repositoryLocator = repositoryLocator ?? RepositoryLocator(client: bobbinClient)
    self.resolver = resolver
    self.transport = transport
  }

  public func list(
    repository: String,
    cursor: String? = nil,
    limit: Int? = nil,
    sort: ArtifactSortOrder = .desc,
    pdsClient: PDSClient? = nil
  ) async throws -> Page<TangledRecord<Artifact>> {
    let resolved = try await resolvedRepository(repository)
    let page = try await bobbinClient.artifacts(
      repositoryDID: resolved.did,
      cursor: cursor,
      limit: limit,
      sort: sort
    )
    guard cursor == nil, let pdsClient else {
      return page
    }
    var records = page.items
    for record in try await pdsClient.artifactRecords(repositoryDID: resolved.did) {
      records.removeAll { $0.uri == record.uri }
      records.append(record)
    }
    records.sort {
      switch sort {
      case .asc:
        $0.value.createdAt.rawValue < $1.value.createdAt.rawValue
      case .desc:
        $0.value.createdAt.rawValue > $1.value.createdAt.rawValue
      }
    }
    if let limit, records.count > limit {
      records.removeSubrange(limit...)
    }
    return Page(items: records, cursor: page.cursor)
  }

  public func view(
    repository: String,
    tag: String,
    pdsClient: PDSClient? = nil
  ) async throws -> ArtifactTagView {
    let resolved = try await resolvedRepository(repository)
    let resolvedTag = try await annotatedTag(repositoryURI: resolved.uri, named: tag)
    var records = try await allArtifacts(repositoryDID: resolved.did)
    if let pdsClient {
      for record in try await pdsClient.artifactRecords(repositoryDID: resolved.did) {
        records.removeAll { $0.uri == record.uri }
        records.append(record)
      }
    }
    records = records.filter {
      $0.value.tagObjectHash == resolvedTag.reference.hash.lowercased()
    }
    return ArtifactTagView(tag: resolvedTag, artifacts: records)
  }

  public func upload(
    repository: String,
    tag: String,
    fileURL: URL,
    name: String? = nil,
    contentType: String = "application/octet-stream",
    force: Bool = false,
    pdsClient: PDSClient
  ) async throws -> TangledRecord<Artifact> {
    let resolved = try await resolvedRepository(repository)
    let resolvedTag = try await annotatedTag(repositoryURI: resolved.uri, named: tag)
    let artifactName = try ArtifactValidation.name(name ?? fileURL.lastPathComponent)
    var records = try await allArtifacts(repositoryDID: resolved.did)
    for record in try await pdsClient.artifactRecords(repositoryDID: resolved.did) {
      records.removeAll { $0.uri == record.uri }
      records.append(record)
    }
    let matches = records.filter {
      $0.value.tagObjectHash == resolvedTag.reference.hash.lowercased()
        && $0.value.name == artifactName
    }
    guard matches.count <= 1 else {
      throw TangledError.upstreamFailed(
        "multiple artifacts match \(tag)/\(artifactName)"
      )
    }
    let existing = matches.first
    if let existing, !force {
      throw ArtifactError.alreadyExists(uri: existing.uri)
    }
    if let existing {
      let owner = try ArtifactValidation.recordOwner(
        existing.uri,
        collection: "sh.tangled.repo.artifact"
      )
      guard owner.rawValue == pdsClient.repoDID else {
        throw ArtifactError.notOwned(uri: existing.uri)
      }
    }
    let data = try ArtifactFileReader.read(fileURL)
    return try await pdsClient.uploadArtifact(
      repositoryURI: resolved.uri,
      repositoryDID: resolved.did,
      tagObjectHash: resolvedTag.reference.hash.lowercased(),
      name: artifactName,
      contentType: contentType,
      data: data,
      replacing: existing
    )
  }

  public func download(
    repository: String,
    tag: String,
    name: String,
    destinationURL: URL,
    force: Bool = false,
    pdsClient: PDSClient? = nil
  ) async throws -> ArtifactDownloadResult {
    let name = try ArtifactValidation.name(name)
    let view = try await view(repository: repository, tag: tag, pdsClient: pdsClient)
    let matches = view.artifacts.filter { $0.value.name == name }
    guard matches.count <= 1 else {
      throw TangledError.upstreamFailed("multiple artifacts match \(tag)/\(name)")
    }
    guard let record = matches.first else {
      throw TangledError.notFound("artifact not found: \(tag)/\(name)")
    }
    _ = try ArtifactDownloadWriter.expectedDigest(cid: record.value.blob.cid)
    try ArtifactDownloadWriter.validateDestination(destinationURL, force: force)
    let stream = try await blobStream(for: record)
    return try await ArtifactDownloadWriter.write(
      stream: stream,
      record: record,
      destinationURL: destinationURL,
      force: force
    )
  }

  @discardableResult
  public func delete(
    repository: String,
    tag: String,
    name: String,
    pdsClient: PDSClient
  ) async throws -> TangledRecord<Artifact> {
    let name = try ArtifactValidation.name(name)
    let view = try await view(repository: repository, tag: tag, pdsClient: pdsClient)
    let matches = view.artifacts.filter { $0.value.name == name }
    guard matches.count <= 1 else {
      throw TangledError.upstreamFailed("multiple artifacts match \(tag)/\(name)")
    }
    guard let record = matches.first else {
      throw TangledError.notFound("artifact not found: \(tag)/\(name)")
    }
    try await pdsClient.deleteArtifact(record)
    return record
  }
}

extension ArtifactService {
  private struct ResolvedRepository {
    let uri: String
    let did: String
  }

  private func resolvedRepository(_ reference: String) async throws -> ResolvedRepository {
    let record = try await repositoryLocator.resolve(reference)
    guard let repositoryDID = record.value.repoDID else {
      throw TangledError.upstreamFailed("repository does not expose a repository DID")
    }
    guard FormatString<DID>(rawValue: repositoryDID).typed != nil else {
      throw TangledError.upstreamFailed("repository exposes an invalid repository DID")
    }
    return ResolvedRepository(uri: record.uri, did: repositoryDID)
  }

  private func annotatedTag(repositoryURI: String, named name: String) async throws -> GitTag {
    guard !name.isEmpty else {
      throw TangledError.invalidRequest("tag must not be empty")
    }
    var cursor: String?
    var seenCursors = Set<String>()
    repeat {
      let page = try await bobbinClient.tags(
        repositoryURI: repositoryURI,
        cursor: cursor,
        limit: 100
      )
      if let tag = page.items.first(where: { $0.reference.name == name }) {
        guard tag.tagger != nil, tag.targetHash != nil else {
          throw ArtifactError.tagNotAnnotated(name)
        }
        _ = try ArtifactValidation.tagData(tag.reference.hash)
        return tag
      }
      guard let next = page.cursor else { break }
      guard seenCursors.insert(next).inserted else {
        throw TangledError.upstreamFailed("tag listing returned a repeated cursor")
      }
      cursor = next
    } while true
    throw TangledError.notFound("tag not found: \(name)")
  }

  private func allArtifacts(repositoryDID: String) async throws
    -> [TangledRecord<Artifact>]
  {
    var result: [TangledRecord<Artifact>] = []
    var cursor: String?
    var seenCursors = Set<String>()
    repeat {
      let page = try await bobbinClient.artifacts(
        repositoryDID: repositoryDID,
        cursor: cursor,
        limit: 1000
      )
      result.append(contentsOf: page.items)
      guard let next = page.cursor else { break }
      guard seenCursors.insert(next).inserted else {
        throw TangledError.upstreamFailed("artifact listing returned a repeated cursor")
      }
      cursor = next
    } while true
    return result
  }

  private func blobStream(
    for record: TangledRecord<Artifact>
  ) async throws -> HTTPBodyStream {
    let owner = try ArtifactValidation.recordOwner(
      record.uri,
      collection: "sh.tangled.repo.artifact"
    )
    guard let document = try await resolver.resolve(did: owner) else {
      throw TangledError.handleNotResolved("DID document not found: \(owner.rawValue)")
    }
    let pdsURL: URL
    do {
      pdsURL = try document.pdsUrl
    } catch {
      throw TangledError.handleNotResolved("PDS not found for \(owner.rawValue)")
    }
    let endpoint =
      pdsURL
      .appendingPathComponent("xrpc", isDirectory: true)
      .appendingPathComponent("com.atproto.sync.getBlob", isDirectory: false)
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw TangledError.invalidRequest("invalid PDS URL")
    }
    components.queryItems = [
      URLQueryItem(name: "did", value: owner.rawValue),
      URLQueryItem(name: "cid", value: record.value.blob.cid),
    ]
    guard let url = components.url else {
      throw TangledError.invalidRequest("invalid PDS blob request")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

    let body: HTTPBodyStream
    let response: HTTPURLResponse
    do {
      (body, response) = try await transport.sendStreaming(request)
    } catch let error as URLError {
      throw TangledError.network(error)
    } catch let error as TangledError {
      throw error
    } catch {
      throw TangledError.transport(String(describing: error))
    }
    switch response.statusCode {
    case 200 ... 299:
      return body
    case 401, 403:
      body.cancel()
      throw TangledError.unauthorized
    case 404:
      body.cancel()
      throw TangledError.notFound("artifact blob not found")
    default:
      body.cancel()
      throw TangledError.serverStatus(response.statusCode, "PDS blob request failed")
    }
  }
}

enum ArtifactFileReader {
  static func read(_ url: URL) throws -> Data {
    guard url.isFileURL else {
      throw TangledError.invalidRequest("artifact file URL must use the file scheme")
    }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      if errno == ELOOP {
        throw TangledError.invalidRequest("artifact file must not be a symbolic link")
      }
      throw TangledError.transport(
        "Unable to open artifact file: \(String(cString: strerror(errno)))"
      )
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }

    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw TangledError.transport(
        "Unable to inspect artifact file: \(String(cString: strerror(errno)))"
      )
    }
    guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
      throw TangledError.invalidRequest("artifact file must be a regular file")
    }
    guard status.st_size <= Artifact.maximumSize else {
      throw ArtifactError.fileTooLarge(
        maximumBytes: Int64(Artifact.maximumSize),
        actualBytes: Int64(status.st_size)
      )
    }

    var data = Data()
    data.reserveCapacity(Int(status.st_size))
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
      data.append(chunk)
      guard data.count <= Artifact.maximumSize else {
        throw ArtifactError.fileTooLarge(
          maximumBytes: Int64(Artifact.maximumSize),
          actualBytes: Int64(data.count)
        )
      }
    }
    return data
  }
}

enum ArtifactDownloadWriter {
  static func write(
    stream: HTTPBodyStream,
    record: TangledRecord<Artifact>,
    destinationURL: URL,
    force: Bool
  ) async throws -> ArtifactDownloadResult {
    let expected = try expectedDigest(cid: record.value.blob.cid)
    try validateDestination(destinationURL, force: force)
    let directory = destinationURL.deletingLastPathComponent()
    let temporaryURL = directory.appendingPathComponent(
      ".\(destinationURL.lastPathComponent).\(UUID().uuidString).download"
    )
    let descriptor = open(
      temporaryURL.path,
      O_WRONLY | O_CREAT | O_EXCL,
      mode_t(S_IRUSR | S_IWUSR)
    )
    guard descriptor >= 0 else {
      throw TangledError.transport(
        "Unable to create temporary artifact file: \(String(cString: strerror(errno)))"
      )
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var completed = false
    defer {
      try? handle.close()
      if !completed {
        _ = unlink(temporaryURL.path)
      }
    }

    var hasher = SHA256()
    var byteCount: Int64 = 0
    do {
      for try await chunk in stream {
        try handle.write(contentsOf: chunk)
        hasher.update(data: chunk)
        byteCount += Int64(chunk.count)
      }
      try handle.synchronize()
      try handle.close()
      let actual = Array(hasher.finalize())
      guard actual == expected else {
        throw ArtifactError.checksumMismatch(
          expectedCID: record.value.blob.cid,
          actualDigest: actual.hexString
        )
      }
      guard rename(temporaryURL.path, destinationURL.path) == 0 else {
        throw TangledError.transport(
          "Unable to replace artifact file: \(String(cString: strerror(errno)))"
        )
      }
      completed = true
      return ArtifactDownloadResult(
        record: record,
        destinationURL: destinationURL,
        byteCount: byteCount,
        verifiedCID: record.value.blob.cid
      )
    } catch is CancellationError {
      stream.cancel()
      throw CancellationError()
    } catch let error as URLError {
      stream.cancel()
      if Task.isCancelled || error.code == .cancelled {
        throw CancellationError()
      }
      throw TangledError.network(error)
    } catch {
      stream.cancel()
      throw error
    }
  }

  static func expectedDigest(cid: String) throws -> [UInt8] {
    guard let link = try? LexLink(cid),
      link.multihash.code == 0x12,
      link.multihash.length == 32,
      let digest = link.multihash.digest,
      digest.count == 32
    else {
      throw ArtifactError.invalidBlobCID(cid)
    }
    return digest
  }

  static func validateDestination(_ url: URL, force: Bool) throws {
    guard url.isFileURL else {
      throw ArtifactError.unsafeDestination("destination URL must use the file scheme")
    }
    let directory = url.deletingLastPathComponent()
    var parentStatus = stat()
    guard lstat(directory.path, &parentStatus) == 0,
      (parentStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    else {
      throw ArtifactError.unsafeDestination("destination parent must be an existing directory")
    }

    var status = stat()
    if lstat(url.path, &status) == 0 {
      guard force else {
        throw ArtifactError.unsafeDestination("destination already exists")
      }
      guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
        throw ArtifactError.unsafeDestination(
          "only an existing regular file can be replaced"
        )
      }
    } else if errno != ENOENT {
      throw ArtifactError.unsafeDestination(
        "unable to inspect destination: \(String(cString: strerror(errno)))"
      )
    }
  }
}

extension [UInt8] {
  fileprivate var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
