import Foundation
import SwiftAtproto
import SwiftTangled
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct RepositoryLocatorTests {
  let ownerDID = "did:plc:owner"
  let repoDID = "did:plc:repository"
  let uri = "at://did:plc:owner/sh.tangled.repo/core"

  @Test func parsesEverySupportedRepositoryReference() throws(TangledError) {
    #expect(try RepositoryReference(uri) == .atURI(uri))
    #expect(try RepositoryReference(repoDID) == .repositoryDID(repoDID))
    #expect(
      try RepositoryReference("alice.example/core")
        == .ownerAndName(owner: "alice.example", name: "core")
    )
    #expect(
      try RepositoryReference("https://tangled.org/alice.example/core.git")
        == .ownerAndName(owner: "alice.example", name: "core")
    )
    #expect(
      try RepositoryReference("git@tangled.org:alice.example/core.git")
        == .ownerAndName(owner: "alice.example", name: "core")
    )
    #expect(
      try RepositoryReference("ssh://git@knot.example/alice.example/core")
        == .ownerAndName(owner: "alice.example", name: "core")
    )
    #expect(
      try RepositoryReference("https://tangled.org/\(repoDID)")
        == .repositoryDID(repoDID)
    )
  }

  @Test func rejectsUnsupportedOrMalformedReferences() {
    for value in [
      "",
      "owner/repository/extra",
      "git@github.com:owner/repository.git",
      "at://did:plc:owner/sh.tangled.issue/core",
      "at://did:plc:owner/sh.tangled.repo",
    ] {
      #expect(throws: TangledError.self) {
        _ = try RepositoryReference(value)
      }
    }
  }

  @Test func resolvesATURIFromOwnerPDSWithoutBobbin() async throws {
    let bobbin = LocatorTransport([])
    let pds = LocatorTransport([.init(statusCode: 200, body: pdsRecord())])
    let locator = makeLocator(bobbin: bobbin, pds: pds)

    let record = try await locator.resolve(uri)

    #expect(record.value.name == "core")
    #expect(await bobbin.requestCount() == 0)
    let request = try #require(await pds.recordedRequests().first)
    #expect(request.url?.path == "/pds/xrpc/com.atproto.repo.getRecord")
    #expect(queryValue("repo", in: request) == ownerDID)
  }

  @Test func repoDIDUsesKnotMetadataThenReadsOwnerPDS() async throws {
    let bobbin = LocatorTransport([])
    let knot = LocatorTransport([.init(statusCode: 200, body: knotDescription())])
    let pds = LocatorTransport([.init(statusCode: 200, body: pdsRecord())])
    let locator = makeLocator(bobbin: bobbin, knot: knot, pds: pds)

    let record = try await locator.resolve(repoDID)

    #expect(record.uri == uri)
    #expect(await bobbin.requestCount() == 0)
    #expect(await knot.requestCount() == 1)
    #expect(await pds.requestCount() == 1)
  }

  @Test func repoDIDFallsBackToBobbinDiscoveryWhenKnotIsUnavailable() async throws {
    let bobbin = LocatorTransport([
      .init(statusCode: 200, body: bobbinRecord())
    ])
    let knot = LocatorTransport([
      .init(statusCode: 503, body: Data())
    ])
    let pds = LocatorTransport([.init(statusCode: 200, body: pdsRecord())])
    let locator = makeLocator(bobbin: bobbin, knot: knot, pds: pds)

    let record = try await locator.resolve(repoDID)

    #expect(record.uri == uri)
    #expect(await bobbin.requestCount() == 1)
    #expect(await pds.requestCount() == 1)
  }

  @Test func repoDIDRejectsMismatchedKnotMetadataWithoutFallback() async {
    let bobbin = LocatorTransport([])
    let knot = LocatorTransport([
      .init(statusCode: 200, body: knotDescription(repoDID: "did:plc:other"))
    ])
    let locator = makeLocator(bobbin: bobbin, knot: knot, pds: LocatorTransport([]))

    await #expect(throws: TangledError.self) {
      _ = try await locator.resolve(repoDID)
    }
    #expect(await bobbin.requestCount() == 0)
  }

  @Test func ownerNameRefreshesBobbinDiscoveryFromPDS() async throws {
    let bobbin = LocatorTransport([
      .init(statusCode: 200, body: searchPage(name: "core", uri: uri))
    ])
    let pds = LocatorTransport([.init(statusCode: 200, body: pdsRecord())])
    let locator = makeLocator(bobbin: bobbin, pds: pds)

    let record = try await locator.resolve("alice.example/core")

    #expect(record.value.knot == "fresh.knot.example")
    #expect(await bobbin.requestCount() == 1)
    #expect(await pds.requestCount() == 1)
  }

  @Test func ownerNameListsPDSRecordsWhenBobbinHasNotIndexedRepository() async throws {
    let bobbin = LocatorTransport([
      .init(statusCode: 200, body: searchPage())
    ])
    let pds = LocatorTransport([
      .init(statusCode: 200, body: pdsList(cursor: "next")),
      .init(statusCode: 200, body: pdsList(includesRecord: true)),
    ])
    let locator = makeLocator(bobbin: bobbin, pds: pds)

    let record = try await locator.resolve("alice.example/core")

    #expect(record.uri == uri)
    let requests = await pds.recordedRequests()
    #expect(requests.count == 2)
    #expect(queryValue("cursor", in: requests[1]) == "next")
  }

  @Test func ownerNameTreatsPDSListingAsAuthoritativeForMissingRepository() async {
    let bobbin = LocatorTransport([
      .init(statusCode: 200, body: searchPage())
    ])
    let pds = LocatorTransport([
      .init(statusCode: 200, body: pdsList())
    ])
    let locator = makeLocator(bobbin: bobbin, pds: pds)

    await #expect(throws: TangledError.self) {
      _ = try await locator.resolve("alice.example/missing")
    }
  }

  @Test func ownerResolutionAcceptsDIDAndReportsMissingHandle() async throws {
    let resolver = LocatorIdentityResolver(handleDID: nil, documents: [:])
    let locator = RepositoryLocator(
      client: makeClient(LocatorTransport([])),
      identityResolver: resolver,
      knotTransport: LocatorTransport([]),
      pdsTransport: LocatorTransport([])
    )

    #expect(try await locator.resolveOwnerDID(ownerDID) == ownerDID)
    await #expect(throws: TangledError.self) {
      _ = try await locator.resolveOwnerDID("missing.example")
    }
  }
}

extension RepositoryLocatorTests {
  fileprivate func makeLocator(
    bobbin: LocatorTransport,
    knot: LocatorTransport = LocatorTransport([]),
    pds: LocatorTransport
  ) -> RepositoryLocator {
    RepositoryLocator(
      client: makeClient(bobbin),
      identityResolver: LocatorIdentityResolver(
        handleDID: ownerDID,
        documents: [
          ownerDID: document(did: ownerDID, endpoint: "https://pds.example/pds"),
          repoDID: document(did: repoDID, endpoint: "https://knot.example/knot"),
        ]
      ),
      knotTransport: knot,
      pdsTransport: pds
    )
  }

  fileprivate func makeClient(_ transport: LocatorTransport) -> BobbinClient {
    BobbinClient(
      baseURL: URL(string: "https://bobbin.example")!,
      transport: transport,
      retryPolicy: BobbinRetryPolicy(maxAttempts: 1)
    )
  }

  fileprivate func pdsRecord() -> Data {
    Data(
      """
      {"uri":"\(uri)","cid":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a","value":\(recordValue())}
      """.utf8
    )
  }

  fileprivate func bobbinRecord() -> Data {
    Data(
      """
      {"uri":"\(uri)","cid":"bafyold","value":{"name":"core","knot":"old.knot.example","repoDid":"\(repoDID)","createdAt":"2026-03-30T09:14:36Z"}}
      """.utf8
    )
  }

  fileprivate func recordValue() -> String {
    """
    {"$type":"sh.tangled.repo","name":"core","knot":"fresh.knot.example","repoDid":"\(repoDID)","createdAt":"2026-07-26T00:00:00Z"}
    """
  }

  fileprivate func knotDescription(repoDID: String? = nil) -> Data {
    Data(
      """
      {"ownerDid":"\(ownerDID)","repoDid":"\(repoDID ?? self.repoDID)","rkey":"core"}
      """.utf8
    )
  }

  fileprivate func searchPage(name: String? = nil, uri: String? = nil) -> Data {
    guard let name, let uri else { return Data(#"{"hits":[]}"#.utf8) }
    return Data(
      """
      {"hits":[{"uri":"\(uri)","nsid":"sh.tangled.repo","score":1,"value":{"name":"\(name)"}}]}
      """.utf8
    )
  }

  fileprivate func pdsList(includesRecord: Bool = false, cursor: String? = nil) -> Data {
    let records =
      includesRecord
      ? """
      [{"uri":"\(uri)","cid":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a","value":\(recordValue())}]
      """ : "[]"
    let cursorField = cursor.map { #","cursor":"\#($0)""# } ?? ""
    return Data(#"{"records":\#(records)\#(cursorField)}"#.utf8)
  }

  fileprivate func document(did: String, endpoint: String) -> DIDDocument {
    DIDDocument(
      context: ["https://www.w3.org/ns/did/v1"],
      did: FormatString(rawValue: did),
      service: [
        .init(
          id: "#atproto_pds",
          type: "AtprotoPersonalDataServer",
          serviceEndpoint: endpoint
        )
      ]
    )
  }

  fileprivate func queryValue(_ name: String, in request: URLRequest) -> String? {
    guard let url = request.url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == name }?.value
  }
}

private struct LocatorIdentityResolver: ATPResolver {
  let handleDID: String?
  let documents: [String: DIDDocument]

  func resolve(handle: Handle) async throws -> DID? {
    try handleDID.map(DID.init(string:))
  }

  func resolve(did: DID) async throws -> DIDDocument? {
    documents[did.rawValue]
  }
}

private actor LocatorTransport: HTTPTransport {
  struct Response: Sendable {
    let statusCode: Int
    let body: Data
  }

  private var responses: [Response]
  private var requests: [URLRequest] = []

  init(_ responses: [Response]) {
    self.responses = responses
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    guard !responses.isEmpty else { throw URLError(.unknown) }
    let response = responses.removeFirst()
    return (
      response.body,
      HTTPURLResponse(
        url: request.url!,
        statusCode: response.statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: [:]
      )!
    )
  }

  func recordedRequests() -> [URLRequest] {
    requests
  }

  func requestCount() -> Int {
    requests.count
  }
}
