import Foundation
import SwiftAtproto
import SwiftTangled
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct RepositoryLocatorTests {
  @Test func parsesEverySupportedRepositoryReference() throws {
    #expect(
      try RepositoryReference(
        "at://did:plc:owner/sh.tangled.repo/3mibd5tthdb22"
      ) == .atURI("at://did:plc:owner/sh.tangled.repo/3mibd5tthdb22")
    )
    #expect(
      try RepositoryReference("did:plc:repository") == .repositoryDID("did:plc:repository")
    )
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
      try RepositoryReference("https://tangled.org/did:plc:repository")
        == .repositoryDID("did:plc:repository")
    )
  }

  @Test func rejectsUnsupportedOrMalformedReferences() {
    for value in [
      "",
      "owner/repository/extra",
      "git@github.com:owner/repository.git",
      "at://did:plc:owner/sh.tangled.issue/3mibd5tthdb22",
      "at://did:plc:owner/sh.tangled.repo",
    ] {
      do {
        _ = try RepositoryReference(value)
        Issue.record("Expected invalid reference: \(value)")
      } catch TangledError.invalidRequest {
        // Expected.
      } catch {
        Issue.record("Unexpected error for \(value): \(error)")
      }
    }
  }

  @Test func resolvesATURIRepoDIDAndOwnerNameThroughExistingAPIs() async throws {
    let repository = response(name: "core", repoDID: "did:plc:repository")
    let firstPage = searchPage(
      hits: [(name: "other", uri: "at://did:plc:owner/sh.tangled.repo/other")],
      cursor: "next-page"
    )
    let secondPage = searchPage(
      hits: [(name: nil, uri: "at://did:plc:owner/sh.tangled.repo/core")]
    )
    let transport = LocatorTransport([
      .init(statusCode: 200, body: repository),
      .init(statusCode: 200, body: repository),
      .init(statusCode: 200, body: firstPage),
      .init(statusCode: 200, body: secondPage),
      .init(statusCode: 200, body: repository),
    ])
    let locator = RepositoryLocator(
      client: makeClient(transport),
      identityResolver: LocatorIdentityResolver(did: "did:plc:owner")
    )

    let byURI = try await locator.resolve(
      "at://did:plc:owner/sh.tangled.repo/3mibd5tthdb22"
    )
    let byDID = try await locator.resolve("did:plc:repository")
    let byName = try await locator.resolve("alice.example/core")

    #expect(byURI.value.name == "core")
    #expect(byDID.value.repoDID == "did:plc:repository")
    #expect(byName.uri == "at://did:plc:owner/sh.tangled.repo/core")

    let requests = await transport.recordedRequests()
    #expect(requests.count == 5)
    #expect(
      queryValues(named: "repo", in: requests[0])
        == ["at://did:plc:owner/sh.tangled.repo/3mibd5tthdb22"]
    )
    #expect(queryValues(named: "repoDid", in: requests[1]) == ["did:plc:repository"])
    #expect(queryValues(named: "q", in: requests[2]) == ["core"])
    #expect(queryValues(named: "nsid", in: requests[2]) == ["sh.tangled.repo"])
    #expect(queryValues(named: "author", in: requests[2]) == ["did:plc:owner"])
    #expect(queryValues(named: "limit", in: requests[2]) == ["100"])
    #expect(queryValues(named: "cursor", in: requests[3]) == ["next-page"])
    #expect(queryValues(named: "repo", in: requests[4]) == [byName.uri])
  }

  @Test func ownerResolutionAcceptsDIDAndReportsMissingHandle() async throws {
    let locator = RepositoryLocator(
      client: makeClient(LocatorTransport([])),
      identityResolver: LocatorIdentityResolver(did: nil)
    )

    #expect(try await locator.resolveOwnerDID("did:plc:owner") == "did:plc:owner")
    do {
      _ = try await locator.resolveOwnerDID("missing.example")
      Issue.record("Expected handleNotResolved")
    } catch TangledError.handleNotResolved(let handle) {
      #expect(handle == "missing.example")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func repoDIDFallsBackToAuthoritativeKnotMetadata() async throws {
    let repoDID = "did:plc:repository"
    let repository = response(name: "playground", repoDID: repoDID)
    let transport = LocatorTransport([
      .init(statusCode: 404, body: Data(#"{"error":"NotFound"}"#.utf8)),
      .init(
        statusCode: 200,
        body: Data(
          """
          {"ownerDid":"did:plc:owner","repoDid":"\(repoDID)","rkey":"playground"}
          """.utf8
        )
      ),
      .init(statusCode: 200, body: repository),
    ])
    let locator = RepositoryLocator(
      client: makeClient(transport),
      identityResolver: LocatorIdentityResolver(
        did: nil,
        didDocument: knotDocument(did: repoDID)
      ),
      knotTransport: transport
    )

    let record = try await locator.resolve(repoDID)

    #expect(record.uri == "at://did:plc:owner/sh.tangled.repo/playground")
    #expect(record.value.repoDID == repoDID)
    let requests = await transport.recordedRequests()
    #expect(requests.count == 3)
    #expect(requests[1].url?.host == "knot.example")
    #expect(requests[1].url?.path == "/base/xrpc/sh.tangled.repo.describeRepo")
    #expect(queryValues(named: "repoDid", in: requests[1]) == [repoDID])
    #expect(
      queryValues(named: "repo", in: requests[2])
        == ["at://did:plc:owner/sh.tangled.repo/playground"]
    )
  }

  @Test func repoDIDFallbackRejectsMismatchedKnotMetadata() async throws {
    let transport = LocatorTransport([
      .init(statusCode: 404, body: Data(#"{"error":"NotFound"}"#.utf8)),
      .init(
        statusCode: 200,
        body: Data(
          """
          {"ownerDid":"did:plc:owner","repoDid":"did:plc:other","rkey":"playground"}
          """.utf8
        )
      ),
    ])
    let locator = RepositoryLocator(
      client: makeClient(transport),
      identityResolver: LocatorIdentityResolver(
        did: nil,
        didDocument: knotDocument(did: "did:plc:repository")
      ),
      knotTransport: transport
    )

    do {
      _ = try await locator.resolve("did:plc:repository")
      Issue.record("Expected mismatched repository DID failure")
    } catch TangledError.upstreamFailed(let message) {
      #expect(message?.contains("did:plc:other") == true)
      #expect(message?.contains("did:plc:repository") == true)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await transport.requestCount() == 2)
  }

  @Test func repeatedPaginationCursorFailsWithoutLooping() async throws {
    let transport = LocatorTransport([
      .init(statusCode: 200, body: searchPage(hits: [], cursor: "same")),
      .init(statusCode: 200, body: searchPage(hits: [], cursor: "same")),
    ])
    let locator = RepositoryLocator(
      client: makeClient(transport),
      identityResolver: LocatorIdentityResolver(did: "did:plc:owner")
    )

    do {
      _ = try await locator.resolve("alice.example/missing")
      Issue.record("Expected upstreamFailed")
    } catch TangledError.upstreamFailed(let message) {
      #expect(message == "repository search returned a repeated cursor")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await transport.requestCount() == 2)
  }
}

extension RepositoryLocatorTests {
  fileprivate func makeClient(_ transport: LocatorTransport) -> BobbinClient {
    BobbinClient(
      baseURL: URL(string: "https://bobbin.example")!,
      transport: transport,
      retryPolicy: BobbinRetryPolicy(maxAttempts: 1)
    )
  }

  fileprivate func response(name: String, repoDID: String) -> Data {
    Data(
      """
      {"uri":"at://did:plc:owner/sh.tangled.repo/\(name)","cid":"bafy\(name)","value":\(String(decoding: responseObject(name: name, repoDID: repoDID), as: UTF8.self))}
      """.utf8
    )
  }

  fileprivate func responseObject(name: String, repoDID: String) -> Data {
    Data(
      """
      {"name":"\(name)","knot":"knot1.tangled.sh","repoDid":"\(repoDID)","createdAt":"2026-03-30T09:14:36Z"}
      """.utf8
    )
  }

  fileprivate func searchPage(hits: [(name: String?, uri: String)], cursor: String? = nil) -> Data {
    let values = hits.map { hit in
      let name = hit.name.map { "\"name\":\"\($0)\"" } ?? ""
      return
        "{\"uri\":\"\(hit.uri)\",\"nsid\":\"sh.tangled.repo\",\"score\":1,\"value\":{\(name)}}"
    }.joined(separator: ",")
    let cursorField = cursor.map { ",\"cursor\":\"\($0)\"" } ?? ""
    return Data("{\"hits\":[\(values)]\(cursorField)}".utf8)
  }

  fileprivate func queryValues(named name: String, in request: URLRequest) -> [String] {
    guard let url = request.url else { return [] }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .filter { $0.name == name }
      .compactMap(\.value) ?? []
  }

  fileprivate func knotDocument(did: String) -> DIDDocument {
    DIDDocument(
      context: ["https://www.w3.org/ns/did/v1"],
      did: FormatString(rawValue: did),
      service: [
        .init(
          id: "#atproto_pds",
          type: "AtprotoPersonalDataServer",
          serviceEndpoint: "https://knot.example/base"
        )
      ]
    )
  }
}

private struct LocatorIdentityResolver: ATPResolver {
  let did: String?
  var didDocument: DIDDocument? = nil

  func resolve(handle: Handle) async throws -> DID? {
    try did.map(DID.init(string:))
  }

  func resolve(did: DID) async throws -> DIDDocument? {
    didDocument
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
