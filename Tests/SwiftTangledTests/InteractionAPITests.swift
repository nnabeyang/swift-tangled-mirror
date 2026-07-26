import Foundation
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

import SwiftTangled

@Suite struct InteractionAPITests {
  @Test func commentsMapMarkdownContextAndPagination() async throws {
    let transport = InteractionTransport([
      .init(statusCode: 200, body: try fixture("comment-page"))
    ])
    let client = makeClient(transport: transport)

    let page = try await client.comments(
      subjectURI: issueURI,
      cursor: "previous-comment-page",
      limit: 25,
      order: .ascending
    )

    #expect(page.cursor == "next-comment-page")
    #expect(page.items.count == 2)
    #expect(page.items[0].cid == "bafyrecomment")
    #expect(page.items[0].value.context.subject.uri == issueURI)
    #expect(page.items[0].value.context.subject.cid == "bafyreissue")
    #expect(page.items[0].value.context.replyTo == nil)
    #expect(page.items[0].value.body.text == "Rendered **comment**")
    #expect(page.items[0].value.body.original == "Original **comment**")
    #expect(
      page.items[0].value.body.blobs.first?.cid
        == "bafkreihwfggzslhujqfjm3pxk2xffi64owlgfxsjmmplvurkljsouqifty"
    )
    #expect(page.items[0].value.body.blobs.first?.mimeType == "image/png")
    #expect(page.items[0].value.createdAt.typed != nil)
    #expect(page.items[1].value.context.replyTo?.cid == "bafyrecomment")
    #expect(page.items[1].value.context.pullRequestRoundIndex == 2)

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.lastPathComponent == "sh.tangled.feed.listComments")
    #expect(queryValues(named: "subject", in: request) == [issueURI])
    #expect(queryValues(named: "cursor", in: request) == ["previous-comment-page"])
    #expect(queryValues(named: "limit", in: request) == ["25"])
    #expect(queryValues(named: "order", in: request) == ["asc"])
  }

  @Test func commentAuthorListAndCountsUseByEndpoints() async throws {
    let pageFixture = try fixture("comment-page")
    let countFixture = try fixture("interaction-count")
    let transport = InteractionTransport([
      .init(statusCode: 200, body: pageFixture),
      .init(statusCode: 200, body: countFixture),
      .init(statusCode: 200, body: countFixture),
    ])
    let client = makeClient(transport: transport)

    let page = try await client.comments(authorDID: authorDID, limit: 2)
    let subjectCount = try await client.commentCount(subjectURI: issueURI)
    let authorCount = try await client.commentCount(authorDID: authorDID)

    #expect(page.items.count == 2)
    #expect(subjectCount == CountSummary(count: 4, distinctAuthors: 3))
    #expect(authorCount == subjectCount)
    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.feed.listCommentsBy")
    #expect(queryValues(named: "subject", in: requests[0]) == [authorDID])
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.feed.countComments")
    #expect(requests[2].url?.lastPathComponent == "sh.tangled.feed.countCommentsBy")
  }

  @Test func reactionListsAndCountsMapKnownValue() async throws {
    let pageFixture = try fixture("reaction-page")
    let countFixture = try fixture("interaction-count")
    let transport = InteractionTransport([
      .init(statusCode: 200, body: pageFixture),
      .init(statusCode: 200, body: pageFixture),
      .init(statusCode: 200, body: countFixture),
      .init(statusCode: 200, body: countFixture),
    ])
    let client = makeClient(transport: transport)

    let subjectPage = try await client.reactions(subjectURI: commentURI, limit: 10)
    let authorPage = try await client.reactions(
      authorDID: authorDID,
      cursor: "previous-reaction-page",
      order: .ascending
    )
    let subjectCount = try await client.reactionCount(subjectURI: commentURI)
    let authorCount = try await client.reactionCount(authorDID: authorDID)

    #expect(subjectPage.items[0].value.subjectURI == commentURI)
    #expect(subjectPage.items[0].value.value == .thumbsUp)
    #expect(subjectPage.items[0].value.createdAt.typed != nil)
    #expect(authorPage.items == subjectPage.items)
    #expect(subjectCount == CountSummary(count: 4, distinctAuthors: 3))
    #expect(authorCount == subjectCount)
    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.feed.listReactions")
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.feed.listReactionsBy")
    #expect(queryValues(named: "subject", in: requests[1]) == [authorDID])
    #expect(queryValues(named: "order", in: requests[1]) == ["asc"])
    #expect(requests[2].url?.lastPathComponent == "sh.tangled.feed.countReactions")
    #expect(requests[3].url?.lastPathComponent == "sh.tangled.feed.countReactionsBy")
  }

  @Test func labelDefinitionsMapValueTypeAndCount() async throws {
    let transport = InteractionTransport([
      .init(statusCode: 200, body: try fixture("label-definition-page")),
      .init(statusCode: 200, body: try fixture("interaction-count")),
    ])
    let client = makeClient(transport: transport)
    let scope = "at://did:plc:owner"

    let page = try await client.labelDefinitions(
      scope: scope,
      cursor: "previous-definition-page",
      limit: 10,
      order: .ascending
    )
    let count = try await client.labelDefinitionCount(scope: scope)

    let definition = try #require(page.items.first?.value)
    #expect(page.cursor == "next-label-definition-page")
    #expect(definition.name == "priority")
    #expect(definition.valueType.kind == .string)
    #expect(definition.valueType.format == .any)
    #expect(definition.valueType.allowedValues == ["high", "medium", "low"])
    #expect(definition.scope == ["sh.tangled.repo.issue", "sh.tangled.repo.pull"])
    #expect(definition.color == "#f59e0b")
    #expect(definition.allowsMultipleValues == true)
    #expect(definition.createdAt.typed != nil)
    #expect(count == CountSummary(count: 4, distinctAuthors: 3))
    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.label.listDefinitions")
    #expect(queryValues(named: "subject", in: requests[0]) == [scope])
    #expect(queryValues(named: "order", in: requests[0]) == ["asc"])
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.label.countDefinitions")
  }

  @Test func labelOperationListsAndCountsMapOperands() async throws {
    let pageFixture = try fixture("label-operation-page")
    let countFixture = try fixture("interaction-count")
    let transport = InteractionTransport([
      .init(statusCode: 200, body: pageFixture),
      .init(statusCode: 200, body: pageFixture),
      .init(statusCode: 200, body: countFixture),
      .init(statusCode: 200, body: countFixture),
    ])
    let client = makeClient(transport: transport)

    let subjectPage = try await client.labelOperations(subjectURI: issueURI, limit: 10)
    let authorPage = try await client.labelOperations(authorDID: authorDID, order: .ascending)
    let subjectCount = try await client.labelOperationCount(subjectURI: issueURI)
    let authorCount = try await client.labelOperationCount(authorDID: authorDID)

    let operation = try #require(subjectPage.items.first?.value)
    #expect(operation.subjectURI == issueURI)
    #expect(operation.additions.first?.definitionURI.hasSuffix("/priority") == true)
    #expect(operation.additions.first?.value == "high")
    #expect(operation.deletions.first?.definitionURI.hasSuffix("/status") == true)
    #expect(operation.deletions.first?.value == "triaged")
    #expect(operation.performedAt.typed != nil)
    #expect(authorPage.items == subjectPage.items)
    #expect(subjectCount == CountSummary(count: 4, distinctAuthors: 3))
    #expect(authorCount == subjectCount)
    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.label.listOps")
    #expect(queryValues(named: "subject", in: requests[0]) == [issueURI])
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.label.listOpsBy")
    #expect(queryValues(named: "subject", in: requests[1]) == [authorDID])
    #expect(requests[2].url?.lastPathComponent == "sh.tangled.label.countOps")
    #expect(requests[3].url?.lastPathComponent == "sh.tangled.label.countOpsBy")
  }

  @Test func rawValueModelsPreserveUnknownValuesAsSingleStrings() throws {
    let unknownReaction = try JSONDecoder().decode(
      ReactionValue.self,
      from: Data(#""🔥""#.utf8)
    )
    let unknownKind = LabelValueKind(rawValue: "decimal")
    let unknownFormat = LabelValueFormat(rawValue: "handle")

    #expect(unknownReaction.rawValue == "🔥")
    #expect(String(decoding: try JSONEncoder().encode(unknownReaction), as: UTF8.self) == #""🔥""#)
    #expect(unknownKind.rawValue == "decimal")
    #expect(unknownFormat.rawValue == "handle")
  }

  @Test func emptyPagesRemainEmpty() async throws {
    let empty = Data(#"{"items":[]}"#.utf8)
    let transport = InteractionTransport([
      .init(statusCode: 200, body: empty),
      .init(statusCode: 200, body: empty),
      .init(statusCode: 200, body: empty),
      .init(statusCode: 200, body: empty),
    ])
    let client = makeClient(transport: transport)

    #expect(try await client.comments(subjectURI: issueURI).items.isEmpty)
    #expect(try await client.reactions(subjectURI: issueURI).items.isEmpty)
    #expect(try await client.labelDefinitions(scope: "at://did:plc:owner").items.isEmpty)
    #expect(try await client.labelOperations(subjectURI: issueURI).items.isEmpty)
  }

  @Test func invalidInputsFailBeforeNetworkRequest() async {
    let transport = InteractionTransport([])
    let client = makeClient(transport: transport)

    await expectInvalidRequest { _ = try await client.comments(subjectURI: "") }
    await expectInvalidRequest { _ = try await client.comments(authorDID: "", limit: 1) }
    await expectInvalidRequest { _ = try await client.comments(subjectURI: issueURI, limit: 0) }
    await expectInvalidRequest { _ = try await client.commentCount(authorDID: "") }
    await expectInvalidRequest { _ = try await client.reactions(subjectURI: "") }
    await expectInvalidRequest { _ = try await client.reactions(authorDID: "", limit: 1) }
    await expectInvalidRequest { _ = try await client.reactions(subjectURI: issueURI, limit: 1001) }
    await expectInvalidRequest { _ = try await client.reactionCount(subjectURI: "") }
    await expectInvalidRequest { _ = try await client.labelDefinitions(scope: "") }
    await expectInvalidRequest {
      _ = try await client.labelDefinitions(scope: "at://did:plc:owner", limit: 0)
    }
    await expectInvalidRequest { _ = try await client.labelOperations(subjectURI: "") }
    await expectInvalidRequest { _ = try await client.labelOperations(authorDID: "", limit: 1) }
    await expectInvalidRequest { _ = try await client.labelOperationCount(authorDID: "") }
    #expect(await transport.requestCount() == 0)
  }

  @Test func malformedEmbeddedRecordIsSkippedByListEndpoints() async throws {
    let malformed = Data(
      #"{"items":[{"uri":"at://did:plc:test/sh.tangled.feed.comment/1","value":{"body":{}}}]}"#.utf8
    )
    let transport = InteractionTransport([.init(statusCode: 200, body: malformed)])

    let page = try await makeClient(transport: transport).comments(subjectURI: issueURI)

    #expect(page.items.isEmpty)
  }

  @Test func closedEnumViolationsAreSkippedByListEndpoints() async throws {
    let unknownReaction = Data(
      #"{"items":[{"uri":"at://did:plc:test/sh.tangled.feed.reaction/1","value":{"subject":"at://did:plc:commenter/sh.tangled.feed.comment/3mrcomment","reaction":"🔥","createdAt":"2026-07-20T18:10:00Z"}}]}"#.utf8
    )
    let unknownLabelValueType = Data(
      #"{"items":[{"uri":"at://did:plc:test/sh.tangled.label.definition/priority","value":{"name":"priority","valueType":{"type":"decimal","format":"handle"},"scope":["sh.tangled.repo.issue"],"createdAt":"2026-07-20T17:00:00Z","multiple":false}}]}"#.utf8
    )
    let transport = InteractionTransport([
      .init(statusCode: 200, body: unknownReaction),
      .init(statusCode: 200, body: unknownLabelValueType),
    ])
    let client = makeClient(transport: transport)

    #expect(try await client.reactions(subjectURI: commentURI).items.isEmpty)
    #expect(
      try await client.labelDefinitions(scope: "at://did:plc:owner").items.isEmpty
    )
  }
}

private extension InteractionAPITests {
  var issueURI: String {
    "at://did:plc:author/sh.tangled.repo.issue/3mrissue"
  }

  var commentURI: String {
    "at://did:plc:commenter/sh.tangled.feed.comment/3mrcomment"
  }

  var authorDID: String {
    "did:plc:author"
  }

  func makeClient(transport: InteractionTransport) -> BobbinClient {
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
      throw InteractionFixtureError.missing(name)
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

private enum InteractionFixtureError: Error {
  case missing(String)
}

private actor InteractionTransport: HTTPTransport {
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
