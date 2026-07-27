import Foundation
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

import SwiftTangled
import TangledLexicons

@Suite struct PullRequestAPITests {
  @Test func pullRequestAndBatchPreserveRoundsInWireOrder() async throws {
    let transport = PullRequestTransport([
      .init(statusCode: 200, body: try fixture("pull-request")),
      .init(statusCode: 200, body: try fixture("pull-requests")),
    ])
    let client = makeClient(transport: transport)
    let uri = "at://did:plc:author/sh.tangled.repo.pull/3mr3itrannf22"

    let pullRequest = try await client.pullRequest(uri: uri)
    let pullRequests = try await client.pullRequests(uris: [uri])

    #expect(pullRequest.uri == uri)
    #expect(pullRequest.cid == "bafyrepullrequest")
    #expect(pullRequest.value.title == "Preserve Tangled rounds")
    #expect(pullRequest.value.body == "Expose every round through SwiftTangled.")
    #expect(pullRequest.value.source == PullRequestSource(branch: "feature/rounds"))
    #expect(
      pullRequest.value.target
        == PullRequestTarget(branch: "main", repositoryDID: "did:plc:repository")
    )
    #expect(pullRequest.value.createdAt.rawValue == "2026-07-20T17:27:07+03:00")
    #expect(pullRequest.value.createdAt.typed != nil)
    #expect(pullRequest.value.mentions == ["did:plc:mentioned"])
    #expect(pullRequest.value.references.count == 1)
    #expect(pullRequest.value.dependentOn?.hasSuffix("/3mr3itr7lb722") == true)
    #expect(pullRequest.value.rounds.count == 2)
    #expect(pullRequest.value.rounds[0].createdAt.rawValue == "2026-07-20T17:27:07Z")
    #expect(
      pullRequest.value.rounds[0].patchBlob.cid
        == "bafkreihwfggzslhujqfjm3pxk2xffi64owlgfxsjmmplvurkljsouqifty"
    )
    #expect(pullRequest.value.rounds[0].patchBlob.mimeType == "application/gzip")
    #expect(pullRequest.value.rounds[0].patchBlob.size == 1_751)
    #expect(
      pullRequest.value.rounds[1].patchBlob.cid
        == "bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a"
    )
    #expect(pullRequests.count == 1)
    #expect(pullRequests[0].value.body == nil)
    #expect(pullRequests[0].value.source?.repositoryDID == "did:plc:source")
    #expect(pullRequests[0].value.mentions.isEmpty)
    #expect(pullRequests[0].value.references.isEmpty)

    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.repo.getPull")
    #expect(queryValues(named: "pull", in: requests[0]) == [uri])
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.repo.getPulls")
    #expect(queryValues(named: "pulls", in: requests[1]) == [uri])
  }

  @Test func emptyPullRequestBatchReturnsWithoutNetworkRequest() async throws {
    let transport = PullRequestTransport([])
    let client = makeClient(transport: transport)

    #expect(try await client.pullRequests(uris: []).isEmpty)
    #expect(await transport.requestCount() == 0)
  }

  @Test func repositoryPullRequestListEncodesFiltersAndDerivedStatus() async throws {
    let transport = PullRequestTransport([
      .init(statusCode: 200, body: try fixture("pull-request-page"))
    ])
    let client = makeClient(transport: transport)

    let page = try await client.pullRequests(
      repositoryDID: "did:plc:repository",
      authorDID: "did:plc:author",
      status: .merged,
      cursor: "previous-pull-page",
      limit: 25,
      order: .ascending
    )

    #expect(page.cursor == "next-pull-page")
    #expect(page.items.count == 2)
    #expect(page.items[0].status == .open)
    #expect(page.items[0].statusUpdatedAt == nil)
    #expect(page.items[0].commentCount == 1)
    #expect(
      page.items[0].record.value.rounds[0].patchBlob.cid
        == "bafkreihwfggzslhujqfjm3pxk2xffi64owlgfxsjmmplvurkljsouqifty"
    )
    #expect(page.items[0].record.value.rounds.count == 2)
    #expect(page.items[1].status == .merged)
    #expect(page.items[1].statusUpdatedAt?.typed != nil)
    #expect(page.items[1].commentCount == 4)

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.lastPathComponent == "sh.tangled.repo.listPulls")
    #expect(queryValues(named: "subject", in: request) == ["did:plc:repository"])
    #expect(queryValues(named: "author", in: request) == ["did:plc:author"])
    #expect(queryValues(named: "status", in: request) == ["merged"])
    #expect(queryValues(named: "cursor", in: request) == ["previous-pull-page"])
    #expect(queryValues(named: "limit", in: request) == ["25"])
    #expect(queryValues(named: "order", in: request) == ["asc"])
  }

  @Test func authorPullRequestListAndCountsUseByEndpoints() async throws {
    let pageFixture = try fixture("pull-request-page")
    let countFixture = try fixture("pull-request-count")
    let transport = PullRequestTransport([
      .init(statusCode: 200, body: pageFixture),
      .init(statusCode: 200, body: countFixture),
      .init(statusCode: 200, body: countFixture),
    ])
    let client = makeClient(transport: transport)

    let page = try await client.pullRequests(
      authorDID: "did:plc:author",
      status: .open,
      limit: 2
    )
    let repositoryCount = try await client.pullRequestCount(
      repositoryDID: "did:plc:repository"
    )
    let authorCount = try await client.pullRequestCount(authorDID: "did:plc:author")

    #expect(page.items.count == 2)
    #expect(repositoryCount == CountSummary(count: 1_331, distinctAuthors: 116))
    #expect(authorCount == repositoryCount)

    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.repo.listPullsBy")
    #expect(queryValues(named: "subject", in: requests[0]) == ["did:plc:author"])
    #expect(queryValues(named: "status", in: requests[0]) == ["open"])
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.repo.countPulls")
    #expect(requests[2].url?.lastPathComponent == "sh.tangled.repo.countPullsBy")
  }

  @Test func pullRequestStatusHistoryAndCountsNormalizeKnownStatuses() async throws {
    let statusFixture = try fixture("pull-request-statuses")
    let countFixture = try fixture("pull-request-status-count")
    let transport = PullRequestTransport([
      .init(statusCode: 200, body: statusFixture),
      .init(statusCode: 200, body: countFixture),
      .init(statusCode: 200, body: statusFixture),
      .init(statusCode: 200, body: countFixture),
    ])
    let client = makeClient(transport: transport)
    let pullRequestURI = "at://did:plc:author/sh.tangled.repo.pull/3mr3itrannf22"

    let pullPage = try await client.pullRequestStatuses(
      pullRequestURI: pullRequestURI,
      cursor: "previous-status-page",
      limit: 10,
      order: .ascending
    )
    let pullCount = try await client.pullRequestStatusCount(
      pullRequestURI: pullRequestURI
    )
    let authorPage = try await client.pullRequestStatuses(
      authorDID: "did:plc:author",
      limit: 10
    )
    let authorCount = try await client.pullRequestStatusCount(authorDID: "did:plc:author")

    #expect(pullPage.cursor == "next-status-page")
    #expect(pullPage.items[0].value.status == .merged)
    #expect(pullPage.items[0].value.pullRequestURI == pullRequestURI)
    #expect(pullPage.items[0].value.createdAt.typed != nil)
    #expect(
      pullPage.items[1].value.status.rawValue
        == "sh.tangled.repo.pull.status.approved"
    )
    #expect(pullCount == CountSummary(count: 2, distinctAuthors: 1))
    #expect(authorPage.items == pullPage.items)
    #expect(authorCount == pullCount)

    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.repo.pull.listStatuses")
    #expect(queryValues(named: "subject", in: requests[0]) == [pullRequestURI])
    #expect(queryValues(named: "cursor", in: requests[0]) == ["previous-status-page"])
    #expect(queryValues(named: "order", in: requests[0]) == ["asc"])
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.repo.pull.countStatuses")
    #expect(requests[2].url?.lastPathComponent == "sh.tangled.repo.pull.listStatusesBy")
    #expect(requests[3].url?.lastPathComponent == "sh.tangled.repo.pull.countStatusesBy")
  }

  @Test func pullRequestStatusCodableUsesSingleRawString() throws {
    let encoded = try JSONEncoder().encode(PullRequestStatus.merged)
    let unknown = try JSONDecoder().decode(
      PullRequestStatus.self,
      from: Data(#""approved""#.utf8)
    )

    #expect(String(decoding: encoded, as: UTF8.self) == #""merged""#)
    #expect(unknown.rawValue == "approved")
  }

  @Test func invalidInputsFailBeforeNetworkRequest() async {
    let transport = PullRequestTransport([])
    let client = makeClient(transport: transport)

    await expectInvalidRequest {
      _ = try await client.pullRequests(uris: Array(repeating: "at://example", count: 51))
    }
    await expectInvalidRequest {
      _ = try await client.pullRequests(uris: [""])
    }
    await expectInvalidRequest {
      _ = try await client.pullRequests(repositoryDID: "", limit: 1)
    }
    await expectInvalidRequest {
      _ = try await client.pullRequests(
        repositoryDID: "did:plc:repository",
        authorDID: ""
      )
    }
    await expectInvalidRequest {
      _ = try await client.pullRequests(
        authorDID: "did:plc:author",
        status: PullRequestStatus(rawValue: "")
      )
    }
    await expectInvalidRequest {
      _ = try await client.pullRequestStatuses(pullRequestURI: "at://pull", limit: 0)
    }
    await expectInvalidRequest {
      _ = try await client.pullRequestStatusCount(authorDID: "")
    }
    #expect(await transport.requestCount() == 0)
  }

  @Test func pullRequestListEndpointsIsolateMalformedRecords() async throws {
    let validValue = #"{"$type":"sh.tangled.repo.pull","title":"Valid","rounds":[{"createdAt":"2026-07-20T17:27:07Z","patchBlob":{"$type":"blob","ref":{"$link":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a"},"mimeType":"application/gzip","size":10}}],"target":{"branch":"main","repo":"did:plc:repository"},"createdAt":"2026-07-20T17:27:07Z"}"#
    let brokenValue = #"{"$type":"sh.tangled.repo.pull","title":"Broken","rounds":[]}"#

    let batch = Data(
      #"""
      {"items":[
        {"cid":"bafyrepullok","uri":"at://did:plc:author/sh.tangled.repo.pull/ok","value":\#(validValue)},
        {"cid":"bafyrepullbad","uri":"at://did:plc:author/sh.tangled.repo.pull/bad","value":\#(brokenValue)}
      ]}
      """#.utf8
    )
    let repoPage = Data(
      #"""
      {"items":[
        {"cid":"bafyrepullok","uri":"at://did:plc:author/sh.tangled.repo.pull/ok","value":\#(validValue),"state":"open","commentCount":0},
        {"cid":"bafyrepullbad","uri":"at://did:plc:author/sh.tangled.repo.pull/bad","value":\#(brokenValue),"state":"open","commentCount":0}
      ],"cursor":"c1"}
      """#.utf8
    )
    let authorPage = Data(
      #"""
      {"items":[
        {"cid":"bafyrepullok","uri":"at://did:plc:author/sh.tangled.repo.pull/ok","value":\#(validValue),"state":"open","commentCount":0},
        {"cid":"bafyrepullbad","uri":"at://did:plc:author/sh.tangled.repo.pull/bad","value":\#(brokenValue),"state":"open","commentCount":0}
      ]}
      """#.utf8
    )
    let statusPage = Data(
      #"""
      {"items":[
        {"cid":"bafyrepstok","uri":"at://did:plc:author/sh.tangled.repo.pull.status/ok","value":{"$type":"sh.tangled.repo.pull.status","pull":"at://did:plc:author/sh.tangled.repo.pull/ok","status":"sh.tangled.repo.pull.status.closed","createdAt":"2026-07-20T17:27:07Z"}},
        {"cid":"bafyrepstbad","uri":"at://did:plc:author/sh.tangled.repo.pull.status/bad","value":{"$type":"sh.tangled.repo.pull.status","status":"sh.tangled.repo.pull.status.closed","createdAt":"2026-07-20T17:27:07Z"}}
      ]}
      """#.utf8
    )
    let transport = PullRequestTransport([
      .init(statusCode: 200, body: batch),
      .init(statusCode: 200, body: repoPage),
      .init(statusCode: 200, body: authorPage),
      .init(statusCode: 200, body: statusPage),
      .init(statusCode: 200, body: statusPage),
    ])
    let client = makeClient(transport: transport)

    let batchResult = try await client.pullRequests(uris: [
      "at://did:plc:author/sh.tangled.repo.pull/ok",
      "at://did:plc:author/sh.tangled.repo.pull/bad",
    ])
    let repoResult = try await client.pullRequests(repositoryDID: "did:plc:repository")
    let authorResult = try await client.pullRequests(authorDID: "did:plc:author")
    let statuses = try await client.pullRequestStatuses(
      pullRequestURI: "at://did:plc:author/sh.tangled.repo.pull/ok"
    )
    let authorStatuses = try await client.pullRequestStatuses(authorDID: "did:plc:author")

    #expect(batchResult.count == 1)
    #expect(batchResult[0].value.title == "Valid")
    #expect(repoResult.items.count == 1)
    #expect(repoResult.items[0].record.value.title == "Valid")
    #expect(authorResult.items.count == 1)
    #expect(statuses.items.count == 1)
    #expect(authorStatuses.items.count == 1)
  }

  @Test func notFoundAndMalformedPullRequestResponseStayTyped() async {
    let transport = PullRequestTransport([
      .init(
        statusCode: 404,
        body: Data(#"{"error":"RecordNotFound","message":"pull not found"}"#.utf8)
      ),
      .init(
        statusCode: 200,
        body: Data(#"{"uri":"at://missing","value":{"title":"missing fields"}}"#.utf8)
      ),
    ])
    let client = makeClient(transport: transport)

    do {
      _ = try await client.pullRequest(uri: "at://missing/pull")
      Testing.Issue.record("Expected notFound")
    } catch Sh.Tangled.RepoGetPull.Error.unexpected(let code, let message) {
      #expect(code == "RecordNotFound")
      #expect(message == "pull not found")
    } catch {
      Testing.Issue.record("Unexpected error: \(error)")
    }

    do {
      _ = try await client.pullRequest(uri: "at://malformed/pull")
      Testing.Issue.record("Expected decoding error")
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Testing.Issue.record("Unexpected error: \(error)")
    }
  }
}

private extension PullRequestAPITests {
  func makeClient(transport: PullRequestTransport) -> BobbinClient {
    BobbinClient(
      baseURL: URL(string: "https://bobbin.example")!,
      transport: transport,
      retryPolicy: BobbinRetryPolicy(maxAttempts: 1)
    )
  }

  func fixture(_ name: String) throws -> Data {
    guard
      let url = Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
      )
    else {
      throw PullRequestFixtureError.missing(name)
    }
    return try Data(contentsOf: url)
  }

  func queryValues(named name: String, in request: URLRequest) -> [String] {
    guard let url = request.url else { return [] }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .filter { $0.name == name }
      .compactMap(\.value) ?? []
  }

  func expectInvalidRequest(_ operation: () async throws -> Void) async {
    do {
      try await operation()
      Testing.Issue.record("Expected invalidRequest")
    } catch TangledError.invalidRequest {
      // Expected.
    } catch {
      Testing.Issue.record("Unexpected error: \(error)")
    }
  }
}

private enum PullRequestFixtureError: Error {
  case missing(String)
}

private actor PullRequestTransport: HTTPTransport {
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
