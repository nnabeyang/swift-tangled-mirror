import Foundation
import SwiftAtproto
import Testing

@testable import SwiftTangled

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite
struct ArtifactAPITests {
  private let repositoryDID = "did:plc:repository"

  @Test func bobbinListAndCountMapGeneratedArtifactTypes() async throws {
    let transport = ArtifactRoutingTransport()
    let client = BobbinClient(
      baseURL: URL(string: "https://bobbin.example")!,
      transport: transport,
      retryPolicy: .init(maxAttempts: 1)
    )

    let page = try await client.artifacts(
      repositoryDID: repositoryDID,
      limit: 25,
      sort: .asc
    )
    let count = try await client.artifactCount(repositoryDID: repositoryDID)

    #expect(page.cursor == "next")
    #expect(page.items.count == 1)
    #expect(page.items[0].uri == "at://did:plc:author/sh.tangled.repo.artifact/3martifact")
    #expect(page.items[0].value.repositoryDID == repositoryDID)
    #expect(page.items[0].value.tagObjectHash == String(repeating: "bb", count: 20))
    #expect(page.items[0].value.name == "artifact-data")
    #expect(page.items[0].value.blob.size == 13)
    #expect(count == CountSummary(count: 3, distinctAuthors: 2))

    let requests = await transport.recordedRequests()
    #expect(query("subject", requests[0]) == repositoryDID)
    #expect(query("limit", requests[0]) == "25")
    #expect(query("order", requests[0]) == "asc")
  }

  @Test func bobbinAcceptsLegacyArtifactTagBytes() async throws {
    let transport = ArtifactRoutingTransport(
      artifactPage: artifactPage(tagJSON: #""u7u7u7u7u7u7u7u7u7u7u7u7u7s=""#)
    )
    let client = BobbinClient(
      baseURL: URL(string: "https://bobbin.example")!,
      transport: transport,
      retryPolicy: .init(maxAttempts: 1)
    )

    let page = try await client.artifacts(repositoryDID: repositoryDID)

    #expect(page.items.count == 1)
    #expect(page.items[0].value.tagObjectHash == String(repeating: "bb", count: 20))
  }

  @Test func bobbinDecodesCurrentWebArtifactShape() async throws {
    let response = Data(
      """
      {"items":[{"uri":"at://did:plc:jge3zxi7lgrfnvhzcgrimeo7/sh.tangled.repo.artifact/3mrhvfbc3p222","cid":"bafyreidcnxgag7i3eruepwqe435sav2d6tbtalgai4luax2l6jdmxosh74","value":{"$type":"sh.tangled.repo.artifact","artifact":{"$type":"blob","$type":"blob","ref":{"$link":"bafkreiauophu4tt4xssqw3c3naywdihdjje5xlduezmdz7ulcqf5grsokq"},"mimeType":"application/gzip","size":8671623},"createdAt":"2026-07-25T15:43:36+03:00","name":"tng-0.1.1-macos-arm64.tar.gz","repoDid":"did:plc:5lkgngawfsd5jh7ch5h5ir2v","tag":{"$bytes":"wskxG0rUL13Z6/4FI0umifCNNTs="},"$type":"sh.tangled.repo.artifact"}}],"cursor":null}
      """.utf8
    )
    let transport = ArtifactRoutingTransport(artifactPage: response)
    let client = BobbinClient(
      baseURL: URL(string: "https://bobbin.example")!,
      transport: transport,
      retryPolicy: .init(maxAttempts: 1)
    )

    let page = try await client.artifacts(
      repositoryDID: "did:plc:5lkgngawfsd5jh7ch5h5ir2v"
    )

    #expect(page.items.count == 1)
    #expect(page.items[0].value.name == "tng-0.1.1-macos-arm64.tar.gz")
    #expect(page.items[0].value.tagObjectHash == "c2c9311b4ad42f5dd9ebfe05234ba689f08d353b")
  }

  @Test(arguments: [
    #"{"$bytes":"not base64"}"#,
    #"{"$bytes":"AA=="}"#,
  ])
  func bobbinRejectsInvalidArtifactTagBytes(_ tagJSON: String) async {
    let transport = ArtifactRoutingTransport(artifactPage: artifactPage(tagJSON: tagJSON))
    let client = BobbinClient(
      baseURL: URL(string: "https://bobbin.example")!,
      transport: transport,
      retryPolicy: .init(maxAttempts: 1)
    )

    await #expect(throws: TangledError.self) {
      _ = try await client.artifacts(repositoryDID: repositoryDID)
    }
  }

  @Test func invalidRepositoryDIDFailsBeforeBobbinRequest() async {
    let transport = ArtifactRoutingTransport()
    let client = BobbinClient(
      baseURL: URL(string: "https://bobbin.example")!,
      transport: transport
    )

    await #expect(throws: TangledError.self) {
      _ = try await client.artifacts(repositoryDID: "not-a-did")
    }
    #expect(await transport.recordedRequests().isEmpty)
  }

  @Test func authoritativeArtifactPaginationIsStableAndPDSWins() throws {
    let indexed = [
      artifactRecord(uriSuffix: "a", name: "indexed-a", createdAt: "2026-07-25T12:00:00Z"),
      artifactRecord(uriSuffix: "a", name: "indexed-a", createdAt: "2026-07-25T12:00:00Z"),
      artifactRecord(uriSuffix: "b", name: "indexed-b", createdAt: "2026-07-25T13:00:00Z"),
      artifactRecord(uriSuffix: "c", name: "indexed-c", createdAt: "2026-07-25T14:00:00Z"),
    ]
    let authoritative = [
      artifactRecord(uriSuffix: "b", name: "fresh-b", createdAt: "2026-07-25T13:00:00Z"),
      artifactRecord(uriSuffix: "d", name: "fresh-d", createdAt: "2026-07-25T15:00:00Z"),
    ]

    let first = try ArtifactPageMerger.merge(
      indexed: indexed,
      authoritative: authoritative,
      position: nil,
      limit: 2,
      sort: .desc
    )
    let cursor = try #require(first.page.cursor)
    let second = try ArtifactPageMerger.merge(
      indexed: indexed,
      authoritative: authoritative,
      position: try ArtifactCursor.decode(cursor, sort: .desc),
      limit: 2,
      sort: .desc
    )

    #expect(first.authoritativeChanges == 2)
    #expect(first.page.items.map(\.value.name) == ["fresh-d", "indexed-c"])
    #expect(second.page.items.map(\.value.name) == ["fresh-b", "indexed-a"])
    #expect(second.page.cursor == nil)
    #expect(Set((first.page.items + second.page.items).map(\.uri)).count == 4)
  }

  @Test func integratedArtifactCursorRejectsInvalidDataAndSortMismatch() throws {
    let record = artifactRecord(
      uriSuffix: "cursor",
      name: "cursor",
      createdAt: "2026-07-25T12:00:00Z"
    )
    let cursor = try ArtifactCursor.encode(record: record, sort: .asc)

    #expect(throws: TangledError.self) {
      _ = try ArtifactCursor.decode(cursor, sort: .desc)
    }
    #expect(throws: TangledError.self) {
      _ = try ArtifactCursor.decode("tng-artifact-v1.invalid", sort: .asc)
    }
  }

  @Test func serviceDownloadsFromRecordAuthorPDSAndVerifiesCID() async throws {
    let transport = ArtifactRoutingTransport()
    let bobbin = BobbinClient(
      baseURL: URL(string: "https://bobbin.example")!,
      transport: transport,
      retryPolicy: .init(maxAttempts: 1)
    )
    let service = ArtifactService(
      bobbinClient: bobbin,
      repositoryLocator: RepositoryLocator(
        client: bobbin,
        identityResolver: ArtifactDIDResolver(),
        knotTransport: transport,
        pdsTransport: transport
      ),
      resolver: ArtifactDIDResolver(),
      transport: transport
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("artifact-data")

    let result = try await service.download(
      repository: repositoryDID,
      tag: "v1.0.0",
      name: "artifact-data",
      destinationURL: destination
    )

    #expect(result.byteCount == 13)
    #expect(result.destinationURL == destination)
    #expect(try Data(contentsOf: destination) == Data("artifact-data".utf8))
    let blobRequest = try #require(
      await transport.recordedRequests().first {
        $0.url?.lastPathComponent == "com.atproto.sync.getBlob"
      }
    )
    #expect(blobRequest.url?.host == "pds.example")
    #expect(query("did", blobRequest) == "did:plc:author")
    #expect(
      query("cid", blobRequest)
        == "bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a"
    )
  }

  @Test func checksumMismatchRemovesTemporaryFileAndKeepsDestinationAbsent() async throws {
    let transport = ArtifactRoutingTransport(blob: Data("wrong".utf8))
    let bobbin = BobbinClient(
      baseURL: URL(string: "https://bobbin.example")!,
      transport: transport,
      retryPolicy: .init(maxAttempts: 1)
    )
    let service = ArtifactService(
      bobbinClient: bobbin,
      repositoryLocator: RepositoryLocator(
        client: bobbin,
        identityResolver: ArtifactDIDResolver(),
        knotTransport: transport,
        pdsTransport: transport
      ),
      resolver: ArtifactDIDResolver(),
      transport: transport
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("artifact-data")

    await #expect(throws: ArtifactError.self) {
      _ = try await service.download(
        repository: repositoryDID,
        tag: "v1.0.0",
        name: "artifact-data",
        destinationURL: destination
      )
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test func lightweightTagIsRejected() async throws {
    let transport = ArtifactRoutingTransport()
    let bobbin = BobbinClient(
      baseURL: URL(string: "https://bobbin.example")!,
      transport: transport,
      retryPolicy: .init(maxAttempts: 1)
    )
    let service = ArtifactService(
      bobbinClient: bobbin,
      repositoryLocator: RepositoryLocator(
        client: bobbin,
        identityResolver: ArtifactDIDResolver(),
        knotTransport: transport,
        pdsTransport: transport
      ),
      resolver: ArtifactDIDResolver(),
      transport: transport
    )

    await #expect(throws: ArtifactError.tagNotAnnotated("snapshot")) {
      _ = try await service.view(repository: repositoryDID, tag: "snapshot")
    }
  }

  @Test func artifactNamesRejectPathsAndControlCharacters() throws {
    let invalid = ["", ".", "..", "dir/file", #"dir\file"#, "line\nbreak", "\0"]
    for name in invalid {
      #expect(throws: ArtifactError.self) {
        _ = try ArtifactValidation.name(name)
      }
    }
    #expect(try ArtifactValidation.name("swift-tangled.tar.gz") == "swift-tangled.tar.gz")
  }

  @Test func uploadFileReaderRejectsDirectorySymlinkAndOversize() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("artifact")
    try Data("ok".utf8).write(to: file)
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    let oversized = directory.appendingPathComponent("oversized")
    #expect(FileManager.default.createFile(atPath: oversized.path, contents: nil))
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(Artifact.maximumSize + 1))
    try handle.close()

    #expect(try ArtifactFileReader.read(file) == Data("ok".utf8))
    #expect(throws: TangledError.self) {
      _ = try ArtifactFileReader.read(directory)
    }
    #expect(throws: TangledError.self) {
      _ = try ArtifactFileReader.read(link)
    }
    #expect(throws: ArtifactError.self) {
      _ = try ArtifactFileReader.read(oversized)
    }
  }

  @Test func downloadWriterRequiresForceAndOnlyReplacesRegularFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("artifact")
    try Data("old".utf8).write(to: destination)
    let record = artifactRecord()

    await #expect(throws: ArtifactError.self) {
      _ = try await ArtifactDownloadWriter.write(
        stream: HTTPBodyStream(buffered: Data("artifact-data".utf8)),
        record: record,
        destinationURL: destination,
        force: false
      )
    }
    let result = try await ArtifactDownloadWriter.write(
      stream: HTTPBodyStream(buffered: Data("artifact-data".utf8)),
      record: record,
      destinationURL: destination,
      force: true
    )
    #expect(result.byteCount == 13)
    #expect(try Data(contentsOf: destination) == Data("artifact-data".utf8))

    let destinationLink = directory.appendingPathComponent("artifact-link")
    try FileManager.default.createSymbolicLink(at: destinationLink, withDestinationURL: destination)
    await #expect(throws: ArtifactError.self) {
      _ = try await ArtifactDownloadWriter.write(
        stream: HTTPBodyStream(buffered: Data("artifact-data".utf8)),
        record: record,
        destinationURL: destinationLink,
        force: true
      )
    }
  }

  private func query(_ name: String, _ request: URLRequest) -> String? {
    guard let url = request.url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == name }?.value
  }

  private func artifactRecord() -> TangledRecord<Artifact> {
    TangledRecord(
      uri: "at://did:plc:author/sh.tangled.repo.artifact/3martifact",
      cid: "bafyrecord",
      value: Artifact(
        repositoryDID: repositoryDID,
        tagObjectHash: String(repeating: "bb", count: 20),
        name: "artifact-data",
        blob: BlobReference(
          cid: "bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a",
          mimeType: "application/octet-stream",
          size: 13
        ),
        createdAt: FormatString(rawValue: "2026-07-25T12:34:56Z")
      )
    )
  }

  private func artifactPage(tagJSON: String) -> Data {
    Data(
      """
      {"items":[{"uri":"at://did:plc:author/sh.tangled.repo.artifact/3martifact","cid":"bafyreirecord","value":{"$type":"sh.tangled.repo.artifact","artifact":{"$type":"blob","$type":"blob","ref":{"$link":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a"},"mimeType":"application/octet-stream","size":13},"createdAt":"2026-07-25T12:34:56Z","name":"artifact-data","repoDid":"\(repositoryDID)","tag":\(tagJSON),"$type":"sh.tangled.repo.artifact"}}]}
      """.utf8
    )
  }

  private func artifactRecord(
    uriSuffix: String,
    name: String,
    createdAt: String
  ) -> TangledRecord<Artifact> {
    TangledRecord(
      uri: "at://did:plc:author/sh.tangled.repo.artifact/\(uriSuffix)",
      cid: "bafy\(uriSuffix)",
      value: Artifact(
        repositoryDID: repositoryDID,
        tagObjectHash: String(repeating: "bb", count: 20),
        name: name,
        blob: BlobReference(
          cid: "bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a",
          mimeType: "application/octet-stream",
          size: 13
        ),
        createdAt: FormatString(rawValue: createdAt)
      )
    )
  }
}

private actor ArtifactRoutingTransport: HTTPTransport {
  private let blob: Data
  private let artifactPage: Data?
  private var requests: [URLRequest] = []

  init(
    blob: Data = Data("artifact-data".utf8),
    artifactPage: Data? = nil
  ) {
    self.blob = blob
    self.artifactPage = artifactPage
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let name = request.url?.lastPathComponent
    let body: Data
    switch name {
    case "sh.tangled.repo.describeRepo":
      body = Data(
        """
        {"ownerDid":"did:plc:owner","repoDid":"did:plc:repository","rkey":"3mibd5tthdb22"}
        """.utf8
      )
    case "com.atproto.repo.getRecord":
      body = try fixture("discovery-repository")
    case "sh.tangled.repo.getRepoByRepoDid":
      body = try fixture("discovery-repository")
    case "sh.tangled.repo.tags":
      body = try fixture("git-tags")
    case "sh.tangled.repo.listArtifacts":
      if query("cursor", request) == nil {
        body = try artifactPage ?? fixture("artifact-page")
      } else {
        body = Data(#"{"items":[]}"#.utf8)
      }
    case "sh.tangled.repo.countArtifacts":
      body = try fixture("artifact-count")
    case "com.atproto.sync.getBlob":
      body = blob
    default:
      body = Data(#"{"error":"NotFound"}"#.utf8)
    }
    let status = name == nil ? 404 : 200
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: nil,
      headerFields: nil
    )!
    return (body, response)
  }

  func recordedRequests() -> [URLRequest] {
    requests
  }

  private func query(_ name: String, _ request: URLRequest) -> String? {
    guard let url = request.url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == name }?.value
  }

  private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(
      forResource: name,
      withExtension: "json",
      subdirectory: "Fixtures"
    )!
    return try Data(contentsOf: url)
  }
}

private struct ArtifactDIDResolver: ATPResolver {
  func resolve(handle: Handle) async throws -> DID? {
    nil
  }

  func resolve(did: DID) async throws -> DIDDocument? {
    DIDDocument(
      context: [],
      did: FormatString(did),
      service: [
        DocService(
          id: "\(did.rawValue)#atproto_pds",
          type: "AtprotoPersonalDataServer",
          serviceEndpoint: "https://pds.example"
        )
      ]
    )
  }
}
