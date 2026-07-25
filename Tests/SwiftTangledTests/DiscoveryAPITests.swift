import Foundation
import SwiftAtproto
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

import SwiftTangled

@Suite struct DiscoveryAPITests {
  @Test func profileAndBatchProfilesPreserveLegacyValues() async throws {
    let transport = DiscoveryTransport([
      .init(statusCode: 200, body: try fixture("discovery-profile")),
      .init(statusCode: 200, body: try fixture("discovery-profiles")),
    ])
    let client = makeClient(transport: transport)

    let profile = try await client.profile(
      uri: "at://did:web:debugman.example/sh.tangled.actor.profile/self"
    )
    let profiles = try await client.profiles(uris: [profile.uri])

    #expect(profile.cid == "bafyreiprofile")
    #expect(
      profile.value.avatar
        == BlobReference(
          cid: "bafkreiavatar",
          mimeType: "image/png",
          size: 198_519
        ))
    #expect(profile.value.links == ["", "https://example.com"])
    #expect(profile.value.stats == ["", "repository-count"])
    #expect(profile.value.preferredHandle == "debugman.example")
    #expect(profiles.count == 1)
    #expect(profiles[0].value.pinnedRepositories == ["did:plc:repo"])

    let requests = await transport.recordedRequests()
    #expect(queryValues(named: "actor", in: requests[0]) == [profile.uri])
    #expect(queryValues(named: "actors", in: requests[1]) == [profile.uri])
  }

  @Test func emptyBatchesReturnWithoutNetworkRequest() async throws {
    let transport = DiscoveryTransport([])
    let client = makeClient(transport: transport)

    #expect(try await client.profiles(uris: []).isEmpty)
    #expect(try await client.repositories(uris: []).isEmpty)
    #expect(await transport.requestCount() == 0)
  }

  @Test func repositoryEndpointsMapDomainModelAndDatetime() async throws {
    let repository = try fixture("discovery-repository")
    let transport = DiscoveryTransport([
      .init(statusCode: 200, body: repository),
      .init(statusCode: 200, body: try fixture("discovery-repositories")),
      .init(statusCode: 200, body: repository),
    ])
    let client = makeClient(transport: transport)

    let byURI = try await client.repository(
      uri: "at://did:plc:owner/sh.tangled.repo/3mibd5tthdb22"
    )
    let batch = try await client.repositories(uris: [byURI.uri])
    let byDID = try await client.repository(repoDID: "did:plc:repository")

    #expect(byURI.value.name == "core")
    #expect(byURI.value.knot == "knot1.tangled.sh")
    #expect(byURI.value.topics == ["atproto", "git"])
    #expect(byURI.value.labels.count == 1)
    #expect(byURI.value.createdAt.rawValue == "2026-03-30T18:14:36+09:00")
    #expect(byURI.value.createdAt.typed != nil)
    #expect(batch.count == 1)
    #expect(byDID.value.repoDID == "did:plc:repository")

    let requests = await transport.recordedRequests()
    #expect(queryValues(named: "repo", in: requests[0]) == [byURI.uri])
    #expect(queryValues(named: "repos", in: requests[1]) == [byURI.uri])
    #expect(queryValues(named: "repoDid", in: requests[2]) == ["did:plc:repository"])
  }

  @Test func repositoryListAndCountEncodePagination() async throws {
    let transport = DiscoveryTransport([
      .init(statusCode: 200, body: try fixture("discovery-repository-page")),
      .init(statusCode: 200, body: try fixture("discovery-repository-count")),
    ])
    let client = makeClient(transport: transport)

    let page = try await client.repositories(
      ownerDID: "did:plc:owner",
      cursor: "previous-page",
      limit: 25,
      order: .ascending
    )
    let count = try await client.repositoryCount(ownerDID: "did:plc:owner")

    #expect(page.items.count == 1)
    #expect(page.cursor == "next-repository-page")
    #expect(count == CountSummary(count: 24, distinctAuthors: 1))

    let requests = await transport.recordedRequests()
    #expect(queryValues(named: "subject", in: requests[0]) == ["did:plc:owner"])
    #expect(queryValues(named: "cursor", in: requests[0]) == ["previous-page"])
    #expect(queryValues(named: "limit", in: requests[0]) == ["25"])
    #expect(queryValues(named: "order", in: requests[0]) == ["asc"])
    #expect(queryValues(named: "subject", in: requests[1]) == ["did:plc:owner"])
  }

  @Test func searchEncodesFiltersAndKeepsArbitraryJSON() async throws {
    let transport = DiscoveryTransport([
      .init(statusCode: 200, body: try fixture("discovery-search"))
    ])
    let client = makeClient(transport: transport)
    let since = FormatString<Date>(rawValue: "2026-01-01T00:00:00Z")
    let until = FormatString<Date>(rawValue: "2026-07-01T00:00:00Z")

    let page = try await client.search(
      "core & swift",
      options: SearchOptions(
        nsid: "sh.tangled.repo",
        authorDID: "did:plc:author",
        repoDID: "did:plc:repository",
        since: since,
        until: until,
        cursor: "00000001",
        limit: 2
      )
    )

    #expect(page.cursor == "00000002")
    #expect(page.items.count == 2)
    #expect(page.items[0].score == 32.904587)
    #expect(page.items[1].score == 4)
    guard case .object(let value) = page.items[1].value else {
      Issue.record("Expected an object search value")
      return
    }
    #expect(value["enabled"] == .bool(true))
    #expect(value["count"] == .integer(3))
    #expect(value["ratio"] == .number(0.5))
    #expect(value["nullable"] == .null)
    #expect(value["tags"] == .array([.string("one"), .string("two")]))

    let request = try #require(await transport.recordedRequests().first)
    #expect(queryValues(named: "q", in: request) == ["core & swift"])
    #expect(queryValues(named: "nsid", in: request) == ["sh.tangled.repo"])
    #expect(queryValues(named: "author", in: request) == ["did:plc:author"])
    #expect(queryValues(named: "repo", in: request) == ["did:plc:repository"])
    #expect(queryValues(named: "since", in: request) == [since.rawValue])
    #expect(queryValues(named: "until", in: request) == [until.rawValue])
    #expect(queryValues(named: "cursor", in: request) == ["00000001"])
    #expect(queryValues(named: "limit", in: request) == ["2"])
  }

  @Test func invalidInputsFailBeforeNetworkRequest() async {
    let transport = DiscoveryTransport([])
    let client = makeClient(transport: transport)

    await expectInvalidRequest {
      _ = try await client.profiles(uris: Array(repeating: "at://example", count: 51))
    }
    await expectInvalidRequest {
      _ = try await client.repositories(ownerDID: "did:plc:owner", limit: 0)
    }
    await expectInvalidRequest {
      _ = try await client.search("")
    }
    await expectInvalidRequest {
      _ = try await client.search(
        "core",
        options: SearchOptions(since: FormatString<Date>(rawValue: "not-a-date"))
      )
    }
    await expectInvalidRequest {
      _ = try await client.search(
        "core",
        options: SearchOptions(
          since: FormatString<Date>(rawValue: "2026-07-01T00:00:00Z"),
          until: FormatString<Date>(rawValue: "2026-01-01T00:00:00Z")
        )
      )
    }
    #expect(await transport.requestCount() == 0)
  }

  @Test func notFoundAndMalformedDomainResponseStayTyped() async throws {
    let transport = DiscoveryTransport([
      .init(
        statusCode: 404,
        body: Data(#"{"error":"RecordNotFound","message":"record not found"}"#.utf8)
      ),
      .init(statusCode: 200, body: Data(#"{"uri":"at://missing","value":{}}"#.utf8)),
    ])
    let client = makeClient(transport: transport)

    do {
      _ = try await client.profile(uri: "at://missing/profile")
      Issue.record("Expected notFound")
    } catch TangledError.notFound(let message) {
      #expect(message == "record not found")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    do {
      _ = try await client.repository(uri: "at://missing/repo")
      Issue.record("Expected decoding error")
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

private extension DiscoveryAPITests {
  func makeClient(transport: DiscoveryTransport) -> BobbinClient {
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
      throw DiscoveryFixtureError.missing(name)
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
      Issue.record("Expected invalidRequest")
    } catch TangledError.invalidRequest {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

private enum DiscoveryFixtureError: Error {
  case missing(String)
}

private actor DiscoveryTransport: HTTPTransport {
  struct Response: Sendable {
    let statusCode: Int
    let body: Data

    init(statusCode: Int, body: Data) {
      self.statusCode = statusCode
      self.body = body
    }
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
