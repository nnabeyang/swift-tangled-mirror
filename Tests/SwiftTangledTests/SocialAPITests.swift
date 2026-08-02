import Foundation
import SwiftAtproto
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

import SwiftTangled

@Suite struct SocialAPITests {
  @Test func starsMapEverySubjectAndUseSubjectAndAuthorEndpoints() async throws {
    let pageFixture = try fixture("star-page")
    let countFixture = try fixture("interaction-count")
    let transport = SocialTransport([
      .init(statusCode: 200, body: pageFixture),
      .init(statusCode: 200, body: pageFixture),
      .init(statusCode: 200, body: countFixture),
      .init(statusCode: 200, body: countFixture),
    ])
    let client = makeClient(transport: transport)

    let repositoryPage = try await client.stars(
      repositoryDID: repositoryDID,
      cursor: "previous-star-page",
      limit: 25,
      order: .ascending
    )
    let authorPage = try await client.stars(authorDID: authorDID)
    let repositoryCount = try await client.starCount(repositoryDID: repositoryDID)
    let authorCount = try await client.starCount(authorDID: authorDID)

    #expect(repositoryPage.cursor == "next-star-page")
    #expect(repositoryPage.items[0].cid == "bafyrestarrepo")
    #expect(repositoryPage.items[0].value.subject == .repository(did: repositoryDID))
    #expect(
      repositoryPage.items[1].value.subject
        == .string(uri: "at://did:plc:author/sh.tangled.string/3mrstring")
    )
    #expect(repositoryPage.items.allSatisfy { $0.value.createdAt.typed != nil })
    #expect(authorPage.items == repositoryPage.items)
    #expect(repositoryCount == CountSummary(count: 4, distinctAuthors: 3))
    #expect(authorCount == repositoryCount)

    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.feed.listStars")
    #expect(queryValues(named: "subject", in: requests[0]) == [repositoryDID])
    #expect(queryValues(named: "cursor", in: requests[0]) == ["previous-star-page"])
    #expect(queryValues(named: "limit", in: requests[0]) == ["25"])
    #expect(queryValues(named: "order", in: requests[0]) == ["asc"])
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.feed.listStarsBy")
    #expect(queryValues(named: "subject", in: requests[1]) == [authorDID])
    #expect(requests[2].url?.lastPathComponent == "sh.tangled.feed.countStars")
    #expect(requests[3].url?.lastPathComponent == "sh.tangled.feed.countStarsBy")
  }

  @Test func followersAndFollowingMapRecordsAndUseMatchingCountEndpoints() async throws {
    let pageFixture = try fixture("follow-page")
    let countFixture = try fixture("interaction-count")
    let transport = SocialTransport([
      .init(statusCode: 200, body: pageFixture),
      .init(statusCode: 200, body: pageFixture),
      .init(statusCode: 200, body: countFixture),
      .init(statusCode: 200, body: countFixture),
    ])
    let client = makeClient(transport: transport)

    let followers = try await client.followers(
      actorDID: followedDID,
      cursor: "previous-follow-page",
      limit: 10,
      order: .ascending
    )
    let following = try await client.following(actorDID: authorDID)
    let followerCount = try await client.followerCount(actorDID: followedDID)
    let followingCount = try await client.followingCount(actorDID: authorDID)

    #expect(followers.cursor == "next-follow-page")
    #expect(followers.items[0].cid == "bafyrefollow")
    #expect(followers.items[0].value.subjectDID == followedDID)
    #expect(followers.items[0].value.createdAt.typed != nil)
    #expect(following.items == followers.items)
    #expect(followerCount == CountSummary(count: 4, distinctAuthors: 3))
    #expect(followingCount == followerCount)

    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.graph.listFollows")
    #expect(queryValues(named: "subject", in: requests[0]) == [followedDID])
    #expect(queryValues(named: "cursor", in: requests[0]) == ["previous-follow-page"])
    #expect(queryValues(named: "limit", in: requests[0]) == ["10"])
    #expect(queryValues(named: "order", in: requests[0]) == ["asc"])
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.graph.listFollowsBy")
    #expect(queryValues(named: "subject", in: requests[1]) == [authorDID])
    #expect(requests[2].url?.lastPathComponent == "sh.tangled.graph.countFollows")
    #expect(requests[3].url?.lastPathComponent == "sh.tangled.graph.countFollowsBy")
  }

  @Test func starSubjectPreservesTheTangledUnionRepresentation() throws {
    let repository = StarSubject.repository(did: repositoryDID)
    let string = StarSubject.string(uri: "at://did:plc:author/sh.tangled.string/3mrstring")

    let repositoryData = try JSONEncoder().encode(repository)
    let stringData = try JSONEncoder().encode(string)

    #expect(try JSONDecoder().decode(StarSubject.self, from: repositoryData) == repository)
    #expect(try JSONDecoder().decode(StarSubject.self, from: stringData) == string)
    #expect(String(decoding: repositoryData, as: UTF8.self).contains("sh.tangled.feed.star#repo"))
    #expect(String(decoding: stringData, as: UTF8.self).contains("sh.tangled.feed.star#string"))
  }

  @Test func emptyPagesRemainEmpty() async throws {
    let empty = Data(#"{"items":[]}"#.utf8)
    let transport = SocialTransport([
      .init(statusCode: 200, body: empty),
      .init(statusCode: 200, body: empty),
      .init(statusCode: 200, body: empty),
      .init(statusCode: 200, body: empty),
    ])
    let client = makeClient(transport: transport)

    #expect(try await client.stars(repositoryDID: repositoryDID).items.isEmpty)
    #expect(try await client.stars(authorDID: authorDID).items.isEmpty)
    #expect(try await client.followers(actorDID: followedDID).items.isEmpty)
    #expect(try await client.following(actorDID: authorDID).items.isEmpty)
  }

  @Test func invalidInputsFailBeforeNetworkRequest() async {
    let transport = SocialTransport([])
    let client = makeClient(transport: transport)

    await expectInvalidRequest { _ = try await client.stars(repositoryDID: "") }
    await expectInvalidRequest { _ = try await client.stars(authorDID: "", limit: 1) }
    await #expect(throws: LexiconConstraintError.self) {
      _ = try await client.stars(repositoryDID: repositoryDID, limit: 0)
    }
    await expectInvalidRequest { _ = try await client.starCount(repositoryDID: "") }
    await expectInvalidRequest { _ = try await client.starCount(authorDID: "") }
    await expectInvalidRequest { _ = try await client.followers(actorDID: "") }
    await expectInvalidRequest { _ = try await client.following(actorDID: "", limit: 1) }
    await #expect(throws: LexiconConstraintError.self) {
      _ = try await client.followers(actorDID: followedDID, limit: 1001)
    }
    await expectInvalidRequest { _ = try await client.followerCount(actorDID: "") }
    await expectInvalidRequest { _ = try await client.followingCount(actorDID: "") }
    #expect(await transport.requestCount() == 0)
  }

  @Test func malformedEmbeddedRecordIsSkippedByListEndpoints() async throws {
    let malformed = Data(
      #"{"items":[{"uri":"at://did:plc:test/sh.tangled.feed.star/1","value":{"subject":{"$type":"unknown"},"createdAt":"2026-07-20T18:20:00Z"}}]}"#.utf8
    )
    let transport = SocialTransport([.init(statusCode: 200, body: malformed)])

    let page = try await makeClient(transport: transport).stars(repositoryDID: repositoryDID)

    #expect(page.items.isEmpty)
  }
}

private extension SocialAPITests {
  var repositoryDID: String {
    "did:plc:repository"
  }

  var authorDID: String {
    "did:plc:author"
  }

  var followedDID: String {
    "did:plc:followed"
  }

  func makeClient(transport: SocialTransport) -> BobbinClient {
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
      throw SocialFixtureError.missing(name)
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

private enum SocialFixtureError: Error {
  case missing(String)
}

private actor SocialTransport: HTTPTransport {
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
