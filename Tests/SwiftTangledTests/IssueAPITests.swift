import Foundation
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

import SwiftTangled

@Suite struct IssueAPITests {
  @Test func issueAndBatchIssuesMapPublicModels() async throws {
    let transport = IssueTransport([
      .init(statusCode: 200, body: try fixture("issue")),
      .init(statusCode: 200, body: try fixture("issues")),
    ])
    let client = makeClient(transport: transport)
    let uri = "at://did:plc:author/sh.tangled.repo.issue/3mqmjxilmrz22"

    let issue = try await client.issue(uri: uri)
    let issues = try await client.issues(uris: [uri])

    #expect(issue.uri == uri)
    #expect(issue.cid == "bafyreissue")
    #expect(issue.value.repositoryDID == "did:plc:repository")
    #expect(issue.value.title == "Support issue reads")
    #expect(issue.value.body == "Expose Bobbin issue data through SwiftTangled.")
    #expect(issue.value.createdAt.rawValue == "2026-07-14T15:37:10Z")
    #expect(issue.value.createdAt.typed != nil)
    #expect(issue.value.mentions == ["did:plc:mentioned"])
    #expect(issue.value.references.count == 1)
    #expect(issues.count == 1)
    #expect(issues[0].value.body == nil)
    #expect(issues[0].value.mentions.isEmpty)
    #expect(issues[0].value.references.isEmpty)

    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.repo.getIssue")
    #expect(queryValues(named: "issue", in: requests[0]) == [uri])
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.repo.getIssues")
    #expect(queryValues(named: "issues", in: requests[1]) == [uri])
  }

  @Test func emptyIssueBatchReturnsWithoutNetworkRequest() async throws {
    let transport = IssueTransport([])
    let client = makeClient(transport: transport)

    #expect(try await client.issues(uris: []).isEmpty)
    #expect(await transport.requestCount() == 0)
  }

  @Test func repositoryIssueListEncodesFiltersAndDerivedState() async throws {
    let transport = IssueTransport([
      .init(statusCode: 200, body: try fixture("issue-page"))
    ])
    let client = makeClient(transport: transport)

    let page = try await client.issues(
      repositoryDID: "did:plc:repository",
      authorDID: "did:plc:author",
      state: .closed,
      cursor: "previous-issue-page",
      limit: 25,
      order: .ascending
    )

    #expect(page.cursor == "next-issue-page")
    #expect(page.items.count == 2)
    #expect(page.items[0].state == .open)
    #expect(page.items[0].stateUpdatedAt == nil)
    #expect(page.items[0].commentCount == 1)
    #expect(page.items[1].state == .closed)
    #expect(page.items[1].stateUpdatedAt?.typed != nil)
    #expect(page.items[1].commentCount == 4)

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.lastPathComponent == "sh.tangled.repo.listIssues")
    #expect(queryValues(named: "subject", in: request) == ["did:plc:repository"])
    #expect(queryValues(named: "author", in: request) == ["did:plc:author"])
    #expect(queryValues(named: "state", in: request) == ["closed"])
    #expect(queryValues(named: "cursor", in: request) == ["previous-issue-page"])
    #expect(queryValues(named: "limit", in: request) == ["25"])
    #expect(queryValues(named: "order", in: request) == ["asc"])
  }

  @Test func authorIssueListAndCountsUseByEndpoints() async throws {
    let pageFixture = try fixture("issue-page")
    let countFixture = try fixture("issue-count")
    let transport = IssueTransport([
      .init(statusCode: 200, body: pageFixture),
      .init(statusCode: 200, body: countFixture),
      .init(statusCode: 200, body: countFixture),
    ])
    let client = makeClient(transport: transport)

    let page = try await client.issues(
      authorDID: "did:plc:author",
      state: .open,
      limit: 2
    )
    let repositoryCount = try await client.issueCount(repositoryDID: "did:plc:repository")
    let authorCount = try await client.issueCount(authorDID: "did:plc:author")

    #expect(page.items.count == 2)
    #expect(repositoryCount == CountSummary(count: 656, distinctAuthors: 285))
    #expect(authorCount == repositoryCount)

    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.repo.listIssuesBy")
    #expect(queryValues(named: "subject", in: requests[0]) == ["did:plc:author"])
    #expect(queryValues(named: "state", in: requests[0]) == ["open"])
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.repo.countIssues")
    #expect(requests[2].url?.lastPathComponent == "sh.tangled.repo.countIssuesBy")
  }

  @Test func issueStateHistoryAndCountsNormalizeKnownStates() async throws {
    let stateFixture = try fixture("issue-states")
    let countFixture = try fixture("issue-state-count")
    let transport = IssueTransport([
      .init(statusCode: 200, body: stateFixture),
      .init(statusCode: 200, body: countFixture),
      .init(statusCode: 200, body: stateFixture),
      .init(statusCode: 200, body: countFixture),
    ])
    let client = makeClient(transport: transport)
    let issueURI = "at://did:plc:author/sh.tangled.repo.issue/3mqmjxilmrz22"

    let issuePage = try await client.issueStates(
      issueURI: issueURI,
      cursor: "previous-state-page",
      limit: 10,
      order: .ascending
    )
    let issueCount = try await client.issueStateCount(issueURI: issueURI)
    let authorPage = try await client.issueStates(authorDID: "did:plc:author", limit: 10)
    let authorCount = try await client.issueStateCount(authorDID: "did:plc:author")

    #expect(issuePage.cursor == "next-state-page")
    #expect(issuePage.items[0].value.state == .closed)
    #expect(issuePage.items[0].value.issueURI == issueURI)
    #expect(issuePage.items[0].value.createdAt.typed != nil)
    #expect(
      issuePage.items[1].value.state.rawValue
        == "sh.tangled.repo.issue.state.triaged"
    )
    #expect(issueCount == CountSummary(count: 2, distinctAuthors: 1))
    #expect(authorPage.items == issuePage.items)
    #expect(authorCount == issueCount)

    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.repo.issue.listStates")
    #expect(queryValues(named: "subject", in: requests[0]) == [issueURI])
    #expect(queryValues(named: "cursor", in: requests[0]) == ["previous-state-page"])
    #expect(queryValues(named: "order", in: requests[0]) == ["asc"])
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.repo.issue.countStates")
    #expect(requests[2].url?.lastPathComponent == "sh.tangled.repo.issue.listStatesBy")
    #expect(requests[3].url?.lastPathComponent == "sh.tangled.repo.issue.countStatesBy")
  }

  @Test func issueStatusCodableUsesSingleRawString() throws {
    let encoded = try JSONEncoder().encode(IssueStatus.open)
    let unknown = try JSONDecoder().decode(
      IssueStatus.self,
      from: Data(#""triaged""#.utf8)
    )

    #expect(String(decoding: encoded, as: UTF8.self) == #""open""#)
    #expect(unknown.rawValue == "triaged")
  }

  @Test func invalidInputsFailBeforeNetworkRequest() async {
    let transport = IssueTransport([])
    let client = makeClient(transport: transport)

    await expectInvalidRequest {
      _ = try await client.issues(uris: Array(repeating: "at://example", count: 51))
    }
    await expectInvalidRequest {
      _ = try await client.issues(uris: [""])
    }
    await expectInvalidRequest {
      _ = try await client.issues(repositoryDID: "", limit: 1)
    }
    await expectInvalidRequest {
      _ = try await client.issues(
        repositoryDID: "did:plc:repository",
        authorDID: ""
      )
    }
    await expectInvalidRequest {
      _ = try await client.issues(
        authorDID: "did:plc:author",
        state: IssueStatus(rawValue: "")
      )
    }
    await expectInvalidRequest {
      _ = try await client.issueStates(issueURI: "at://issue", limit: 0)
    }
    await expectInvalidRequest {
      _ = try await client.issueStateCount(authorDID: "")
    }
    #expect(await transport.requestCount() == 0)
  }

  @Test func notFoundAndMalformedIssueResponseStayTyped() async {
    let transport = IssueTransport([
      .init(
        statusCode: 404,
        body: Data(#"{"error":"RecordNotFound","message":"issue not found"}"#.utf8)
      ),
      .init(
        statusCode: 200,
        body: Data(#"{"uri":"at://missing","value":{"title":"missing fields"}}"#.utf8)
      ),
    ])
    let client = makeClient(transport: transport)

    do {
      _ = try await client.issue(uri: "at://missing/issue")
      Testing.Issue.record("Expected notFound")
    } catch TangledError.notFound(let message) {
      #expect(message == "issue not found")
    } catch {
      Testing.Issue.record("Unexpected error: \(error)")
    }

    do {
      _ = try await client.issue(uri: "at://malformed/issue")
      Testing.Issue.record("Expected decoding error")
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Testing.Issue.record("Unexpected error: \(error)")
    }
  }
}

private extension IssueAPITests {
  func makeClient(transport: IssueTransport) -> BobbinClient {
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
      throw IssueFixtureError.missing(name)
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

private enum IssueFixtureError: Error {
  case missing(String)
}

private actor IssueTransport: HTTPTransport {
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
