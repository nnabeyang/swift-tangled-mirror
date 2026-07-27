import Foundation
import HTTPTypes
import SwiftAtproto
import TangledLexicons

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension BobbinClient {
  /// Downloads an archive into memory. Use a byte range to bound the response when the server
  /// supports partial content. Streaming downloads are intentionally provided separately.
  public func archive(
    repositoryURI: String,
    ref: String,
    format: GitArchiveFormat = .tarGzip,
    prefix: String? = nil,
    byteRange: GitArchiveByteRange? = nil
  ) async throws -> GitArchive {
    let content: Data
    let response: HTTPURLResponse
    do {
      (content, response) = try await responseWithMetadata(
        archiveRequest(
          repositoryURI: repositoryURI,
          ref: ref,
          format: format,
          prefix: prefix,
          byteRange: byteRange
        )
      )
    } catch let error as UnExpectedError {
      throw Sh.Tangled.RepoArchive.Error(error: error)
    }
    return GitArchive(
      content: content,
      statusCode: response.statusCode,
      contentType: response.value(forHTTPHeaderField: "Content-Type"),
      contentLength: response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
      contentRange: response.value(forHTTPHeaderField: "Content-Range"),
      contentDisposition: response.value(forHTTPHeaderField: "Content-Disposition"),
      acceptRanges: response.value(forHTTPHeaderField: "Accept-Ranges")
    )
  }

  /// Streams an archive as bounded `Data` chunks without retaining the complete response.
  public func archiveStream(
    repositoryURI: String,
    ref: String,
    format: GitArchiveFormat = .tarGzip,
    prefix: String? = nil,
    byteRange: GitArchiveByteRange? = nil
  ) async throws -> GitArchiveStream {
    let body: HTTPBodyStream
    let response: HTTPURLResponse
    do {
      (body, response) = try await streamingResponseWithMetadata(
        archiveRequest(
          repositoryURI: repositoryURI,
          ref: ref,
          format: format,
          prefix: prefix,
          byteRange: byteRange
        )
      )
    } catch let error as UnExpectedError {
      throw Sh.Tangled.RepoArchive.Error(error: error)
    }
    return GitArchiveStream(
      body: body,
      statusCode: response.statusCode,
      contentType: response.value(forHTTPHeaderField: "Content-Type"),
      contentLength: response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
      contentRange: response.value(forHTTPHeaderField: "Content-Range"),
      contentDisposition: response.value(forHTTPHeaderField: "Content-Disposition"),
      acceptRanges: response.value(forHTTPHeaderField: "Accept-Ranges")
    )
  }

  public func defaultBranch(repositoryURI: String) async throws -> GitDefaultBranch {
    try validateGitRepositoryURI(repositoryURI)
    let response = try await generatedQuery {
      try await RepoGetDefaultBranch(repo: repositoryURI)
    }
    return GitDefaultBranch(
      name: response.name,
      hash: response.hash,
      shortHash: response.shortHash,
      when: response.when,
      message: response.message,
      author: response.author.map {
        GitSignature(name: $0.name, email: $0.email, when: $0.when)
      }
    )
  }

  public func branches(
    repositoryURI: String,
    cursor: String? = nil,
    limit: Int? = nil
  ) async throws -> Page<GitBranch> {
    try validateGitRepositoryURI(repositoryURI)
    let offset = try gitReferenceOffset(cursor, name: "branches")
    let pageLimit = try gitReferenceLimit(limit)
    let data = try await generatedQuery {
      try await RepoBranches(cursor: cursor, limit: limit, repo: repositoryURI)
    }
    let wire: WireGitBranches
    do {
      wire = try JSONDecoder().decode(WireGitBranches.self, from: data)
    } catch {
      throw TangledError.decoding(error)
    }
    let items = wire.branches.map(\.model)
    return Page(
      items: items,
      cursor: gitReferenceNextCursor(offset: offset, itemCount: items.count, limit: pageLimit)
    )
  }

  public func tags(
    repositoryURI: String,
    cursor: String? = nil,
    limit: Int? = nil
  ) async throws -> Page<GitTag> {
    try validateGitRepositoryURI(repositoryURI)
    let offset = try gitReferenceOffset(cursor, name: "tags")
    let pageLimit = try gitReferenceLimit(limit)
    let data = try await generatedQuery {
      try await RepoTags(cursor: cursor, limit: limit, repo: repositoryURI)
    }
    let wire: WireGitTags
    do {
      wire = try JSONDecoder().decode(WireGitTags.self, from: data)
    } catch {
      throw TangledError.decoding(error)
    }
    let items = wire.tags.map(\.model)
    return Page(
      items: items,
      cursor: gitReferenceNextCursor(offset: offset, itemCount: items.count, limit: pageLimit)
    )
  }

  public func describeRepository(
    repositoryURI: String,
    repositoryDID: String
  ) async throws -> GitRepositoryDescription {
    try validateGitRepositoryURI(repositoryURI)
    try validateDID(repositoryDID, name: "repository DID")
    // Bobbin uses the repository AT URI to select the knot, while the knot's generated
    // describeRepo query accepts only repoDid. Send both routing and upstream parameters.
    let response: Sh.Tangled.RepoDescribeRepo_Output
    do {
      response = try await get(
        nsid: Sh.Tangled.RepoDescribeRepo.id,
        queryItems: [
          URLQueryItem(name: "repo", value: repositoryURI),
          URLQueryItem(name: "repoDid", value: repositoryDID),
        ]
      )
    } catch let error as UnExpectedError {
      throw Sh.Tangled.RepoDescribeRepo.Error(error: error)
    }
    return GitRepositoryDescription(
      ownerDID: response.ownerDid.rawValue,
      repositoryDID: response.repoDid.rawValue,
      rkey: response.rkey.rawValue
    )
  }

  public func languages(
    repositoryURI: String,
    ref: String? = nil
  ) async throws -> GitLanguageReport {
    try validateGitRepositoryURI(repositoryURI)
    if let ref { try requireNonempty(ref, name: "git ref") }
    let response = try await generatedQuery {
      try await RepoLanguages(ref: ref, repo: repositoryURI)
    }
    return GitLanguageReport(
      ref: response.ref,
      languages: response.languages?.map {
        GitLanguage(
          name: $0.name,
          size: $0.size,
          percentage: $0.percentage,
          fileCount: $0.fileCount,
          color: $0.color,
          extensions: $0.extensions
        )
      } ?? [],
      totalFiles: response.totalFiles,
      totalSize: response.totalSize
    )
  }

  public func tree(
    repositoryURI: String,
    ref: String,
    path: String? = nil
  ) async throws -> GitTree {
    try validateGitRepositoryURI(repositoryURI)
    try requireNonempty(ref, name: "git ref")
    if let path { try requireNonempty(path, name: "tree path") }
    let response = try await generatedQuery {
      try await RepoTree(path: path, ref: ref, repo: repositoryURI)
    }
    return GitTree(
      ref: response.ref,
      parent: response.parent,
      parentPath: response.dotdot,
      readme: response.readme.map {
        GitTreeReadme(filename: $0.filename, contents: $0.contents)
      },
      lastCommit: response.lastCommit.map(gitLastCommit),
      entries: response.files.map {
        GitTreeEntry(
          name: $0.name,
          mode: $0.mode,
          size: $0.size,
          lastCommit: $0.last_commit.map(gitLastCommit)
        )
      }
    )
  }

  public func log(
    repositoryURI: String,
    ref: String,
    path: String? = nil,
    cursor: String? = nil,
    limit: Int? = nil
  ) async throws -> GitLogPage {
    try validateGitRepositoryURI(repositoryURI)
    try requireNonempty(ref, name: "git ref")
    if let path { try requireNonempty(path, name: "log path") }
    let offset = try gitLogOffset(cursor)
    if let limit, !(1 ... 100).contains(limit) {
      throw TangledError.invalidRequest("limit must be between 1 and 100")
    }
    let response = try await generatedQuery {
      try await RepoLog(
        cursor: cursor,
        limit: limit,
        path: path,
        ref: ref,
        repo: repositoryURI
      )
    }
    guard let rawCommits = response.commits else {
      throw TangledError.decoding(GitContentError.missingLogField("commits"))
    }
    guard let responseRef = response.ref else {
      throw TangledError.decoding(GitContentError.missingLogField("ref"))
    }
    guard let total = response.total else {
      throw TangledError.decoding(GitContentError.missingLogField("total"))
    }
    guard let page = response.page else {
      throw TangledError.decoding(GitContentError.missingLogField("page"))
    }
    let commits = rawCommits.map(\.gitCommit)
    // Knot currently interprets the cursor as a numeric offset, although the Lexicon
    // describes it as a commit SHA. Keep the public cursor opaque while matching reality.
    let nextOffset = offset + commits.count
    let nextCursor = nextOffset < total ? String(nextOffset) : nil
    return GitLogPage(
      commits: commits,
      cursor: nextCursor,
      ref: responseRef,
      total: total,
      page: page
    )
  }

  public func blob(repositoryURI: String, ref: String, path: String) async throws -> GitBlob {
    try validateGitRepositoryURI(repositoryURI)
    try requireNonempty(ref, name: "git ref")
    try requireNonempty(path, name: "blob path")
    let response = try await generatedQuery {
      // Bobbin resolves an AT URI to the knot target even though this generated parameter
      // is nominally a DID in the upstream Lexicon.
      try await RepoBlob(
        path: path,
        ref: ref,
        repo: FormatString<DID>(rawValue: repositoryURI)
      )
    }
    let encoding = response.encoding.map { GitBlobEncoding(rawValue: $0.rawValue) }
    let content: Data?
    switch (response.content, encoding) {
    case (nil, _):
      content = nil
    case (let value?, .base64):
      guard let decoded = Data(base64Encoded: value) else {
        throw TangledError.decoding(GitContentError.invalidBase64)
      }
      content = decoded
    case (let value?, _):
      content = Data(value.utf8)
    }
    return GitBlob(
      ref: response.ref,
      path: response.path,
      content: content,
      encoding: encoding,
      size: response.size,
      isBinary: response.isBinary ?? false,
      mimeType: response.mimeType,
      submodule: response.submodule.map {
        GitSubmodule(name: $0.name, url: $0.url, branch: $0.branch)
      },
      lastCommit: response.lastCommit.map(gitLastCommit),
      fileTooLarge: response.fileTooLarge ?? false
    )
  }
}

private extension BobbinClient {
  func archiveRequest(
    repositoryURI: String,
    ref: String,
    format: GitArchiveFormat,
    prefix: String?,
    byteRange: GitArchiveByteRange?
  ) throws -> XRPCRequestComponents {
    try validateGitRepositoryURI(repositoryURI)
    try requireNonempty(ref, name: "git ref")
    if let prefix { try requireNonempty(prefix, name: "archive prefix") }

    var headers = HTTPFields()
    headers[.accept] = "*/*"
    if let byteRange {
      headers[HTTPField.Name("Range")!] = try archiveRangeHeader(byteRange)
    }
    var queryItems = [
      URLQueryItem(name: "format", value: format.rawValue),
      URLQueryItem(name: "ref", value: ref),
      URLQueryItem(name: "repo", value: repositoryURI),
    ]
    if let prefix {
      queryItems.append(URLQueryItem(name: "prefix", value: prefix))
    }
    return XRPCRequestComponents(
      nsId: Sh.Tangled.RepoArchive.id,
      queryItems: queryItems.map(percentEncodedQueryItem),
      headers: headers,
      method: .get
    )
  }

  func archiveRangeHeader(_ range: GitArchiveByteRange) throws -> String {
    switch range {
    case .bytes(let values):
      guard values.lowerBound >= 0 else {
        throw TangledError.invalidRequest("archive byte range must not be negative")
      }
      return "bytes=\(values.lowerBound)-\(values.upperBound)"
    case .from(let offset):
      guard offset >= 0 else {
        throw TangledError.invalidRequest("archive byte range must not be negative")
      }
      return "bytes=\(offset)-"
    case .suffix(let length):
      guard length > 0 else {
        throw TangledError.invalidRequest("archive byte range suffix must be greater than zero")
      }
      return "bytes=-\(length)"
    }
  }

  func validateDID(_ value: String, name: String) throws {
    guard FormatString<DID>(rawValue: value).typed != nil else {
      throw TangledError.invalidRequest("\(name) must be a valid DID")
    }
  }

  func gitReferenceOffset(_ cursor: String?, name: String) throws -> Int {
    guard let cursor else { return 0 }
    guard let offset = Int(cursor), offset >= 0 else {
      throw TangledError.invalidRequest("\(name) cursor must be a non-negative integer")
    }
    return offset
  }

  func gitReferenceLimit(_ limit: Int?) throws -> Int {
    guard let limit else { return 50 }
    guard (1 ... 100).contains(limit) else {
      throw TangledError.invalidRequest("limit must be between 1 and 100")
    }
    return limit
  }

  func gitReferenceNextCursor(offset: Int, itemCount: Int, limit: Int) -> String? {
    // Knot treats the cursor as an offset but omits a cursor and total from its response.
    // Keep the public cursor opaque and derive the next offset when a full page is returned.
    itemCount == limit ? String(offset + itemCount) : nil
  }

  func gitLogOffset(_ cursor: String?) throws -> Int {
    guard let cursor else { return 0 }
    guard let offset = Int(cursor), offset >= 0 else {
      throw TangledError.invalidRequest("log cursor must be a non-negative integer")
    }
    return offset
  }
}

private struct WireGitBranches: Decodable {
  let branches: [WireGitBranch]
}

private struct WireGitBranch: Decodable {
  let reference: WireGitReference
  let commit: WireGoGitCommit?
  let isDefault: Bool?

  enum CodingKeys: String, CodingKey {
    case reference, commit
    case isDefault = "is_default"
  }

  var model: GitBranch {
    GitBranch(
      reference: reference.model,
      commit: commit?.model,
      isDefault: isDefault ?? false
    )
  }
}

private struct WireGitTags: Decodable {
  let tags: [WireGitTag]

  private enum CodingKeys: String, CodingKey {
    case tags
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tags = try container.decodeIfPresent([WireGitTag].self, forKey: .tags) ?? []
  }
}

private struct WireGitTag: Decodable {
  let name: String
  let hash: String
  let tag: WireAnnotatedGitTag?
  let message: String?

  var model: GitTag {
    GitTag(
      reference: GitReference(name: name, hash: hash),
      tagger: tag?.tagger.model,
      message: message ?? tag?.message,
      targetHash: tag.map { gitHash($0.target) }
    )
  }
}

private struct WireAnnotatedGitTag: Decodable {
  let tagger: WireGitSignature
  let message: String
  let target: [UInt8]

  enum CodingKeys: String, CodingKey {
    case tagger = "Tagger"
    case message = "Message"
    case target = "Target"
  }
}

private struct WireGitReference: Decodable {
  let name: String
  let hash: String

  var model: GitReference { GitReference(name: name, hash: hash) }
}

private struct WireGoGitCommit: Decodable {
  let hash: [UInt8]
  let author: WireGitSignature
  let committer: WireGitSignature
  let message: String
  let treeHash: [UInt8]
  let parentHashes: [[UInt8]]

  enum CodingKeys: String, CodingKey {
    case hash = "Hash"
    case author = "Author"
    case committer = "Committer"
    case message = "Message"
    case treeHash = "TreeHash"
    case parentHashes = "ParentHashes"
  }

  var model: GitCommit {
    GitCommit(
      hash: gitHash(hash),
      author: author.model,
      committer: committer.model,
      message: message,
      tree: gitHash(treeHash),
      parentHashes: parentHashes.map(gitHash)
    )
  }
}

private func gitLastCommit(_ value: Sh.Tangled.RepoTree_LastCommit) -> GitLastCommit {
  GitLastCommit(
    hash: value.hash,
    message: value.message,
    when: value.when,
    author: value.author.map {
      GitSignature(name: $0.name, email: $0.email, when: $0.when)
    }
  )
}

private func gitLastCommit(_ value: Sh.Tangled.RepoBlob_LastCommit) -> GitLastCommit {
  GitLastCommit(
    hash: value.hash,
    message: value.message,
    when: value.when,
    author: value.author.map {
      GitSignature(name: $0.name, email: $0.email, when: $0.when)
    }
  )
}

private extension Sh.Tangled.RepoLog_Commit {
  var gitCommit: GitCommit {
    GitCommit(
      hash: self.this,
      author: author.gitSignature,
      committer: committer.gitSignature,
      message: message,
      tree: tree,
      parentHashes: parent_hashes?.map {
        $0.map { String(format: "%02x", $0) }.joined()
      } ?? [],
      changeID: change_id
    )
  }
}

private extension Sh.Tangled.RepoLog_Signature {
  var gitSignature: GitSignature {
    GitSignature(name: Name, email: Email, when: When)
  }
}

private struct WireGitSignature: Decodable {
  let name: String
  let email: String
  let when: FormatString<Date>

  enum CodingKeys: String, CodingKey {
    case name = "Name"
    case email = "Email"
    case when = "When"
  }

  var model: GitSignature { GitSignature(name: name, email: email, when: when) }
}

private func gitHash(_ bytes: [UInt8]) -> String {
  bytes.map { String(format: "%02x", $0) }.joined()
}

private enum GitContentError: Error {
  case invalidBase64
  case missingLogField(String)
}
