import Foundation
import SwiftAtproto
import Testing

@testable import SwiftTangled

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct BobbinClientTests {
  @Test func coverageUsesConfiguredBaseURLAndDecodesWarmupFixture() async throws {
    let transport = MockHTTPTransport([
      .response(statusCode: 200, body: try fixture("bobbin-coverage-warming"))
    ])
    let client = makeClient(transport: transport)

    let coverage = try await client.coverage()

    #expect(coverage == BobbinCoverage(ready: false, eventsProcessed: 45_588, lastCursor: 51_658))
    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(
      requests[0].url?.absoluteString
        == "https://bobbin.example/base/xrpc/sh.tangled.bobbin.getCoverage"
    )
    #expect(requests[0].value(forHTTPHeaderField: "Accept") == "application/json")
  }

  @Test func coverageDecodesReadyFixture() async throws {
    let transport = MockHTTPTransport([
      .response(statusCode: 200, body: try fixture("bobbin-coverage-ready"))
    ])

    let coverage = try await makeClient(transport: transport).coverage()

    #expect(coverage == BobbinCoverage(ready: true, eventsProcessed: 106_085, lastCursor: 116_527))
  }

  @Test func generatedQueryPreservesConfiguredBasePath() async throws {
    let transport = MockHTTPTransport([
      .response(statusCode: 200, body: try fixture("discovery-repository-count"))
    ])
    let client = makeClient(transport: transport)

    let count = try await client.repositoryCount(ownerDID: "did:plc:owner")

    #expect(count == CountSummary(count: 24, distinctAuthors: 1))
    let request = try #require(await transport.recordedRequests().first)
    #expect(
      request.url?.absoluteString
        == "https://bobbin.example/base/xrpc/sh.tangled.repo.countRepos?subject=did%3Aplc%3Aowner"
    )
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
  }

  @Test func generatedTransportRejectsProcedures() async {
    let client = makeClient(transport: MockHTTPTransport([]))
    let request = XRPCRequestComponents(
      nsId: "com.atproto.repo.putRecord",
      queryItems: [],
      headers: [:],
      method: .post
    )

    do {
      _ = try await client.response(request)
      Issue.record("Expected invalidRequest")
    } catch TangledError.invalidRequest(let message) {
      #expect(message == "BobbinClient supports XRPC queries only")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func rawQueryEncodesFieldsAndPreservesDuplicates() async throws {
    let body = Data(#"{"ready":true}"#.utf8)
    let transport = MockHTTPTransport([
      .response(statusCode: 200, body: body)
    ])
    let client = makeClient(transport: transport)

    let response = try await client.rawQuery(
      nsid: "sh.tangled.actor.getProfile",
      queryItems: [
        URLQueryItem(name: "did", value: "did:plc:alice+bob /雪"),
        URLQueryItem(name: "did", value: "second"),
        URLQueryItem(name: "empty", value: ""),
      ],
      allowsRawResponse: false
    )

    #expect(response == body)
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.httpMethod == "GET")
    #expect(
      request.url?.absoluteString
        == "https://bobbin.example/base/xrpc/sh.tangled.actor.getProfile?did=did%3Aplc%3Aalice%2Bbob%20%2F%E9%9B%AA&did=second&empty="
    )
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
  }

  @Test func rawResponseRequiresExplicitOptIn() async throws {
    let body = Data([0x00, 0xFF, 0x0A])
    let transport = MockHTTPTransport([
      .response(statusCode: 200, body: body)
    ])
    let client = makeClient(transport: transport)

    do {
      _ = try await client.rawQuery(
        nsid: "sh.tangled.repo.archive",
        queryItems: [],
        allowsRawResponse: false
      )
      Issue.record("Expected raw opt-in failure")
    } catch TangledError.invalidRequest(let message) {
      #expect(message == "sh.tangled.repo.archive requires --raw")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await transport.requestCount() == 0)

    let response = try await client.rawQuery(
      nsid: "sh.tangled.repo.archive",
      queryItems: [],
      allowsRawResponse: true
    )

    #expect(response == body)
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
  }

  @Test func rawQueryRejectsNonBobbinAndNonQueryNSIDsBeforeRequest() async {
    let transport = MockHTTPTransport([])
    let client = makeClient(transport: transport)
    let rejectedNSIDs = [
      "com.atproto.repo.putRecord",
      "sh.tangled.ci.getPipeline",
      "sh.tangled.repo",
      "sh.tangled.repo.create",
    ]

    for nsid in rejectedNSIDs {
      do {
        _ = try await client.rawQuery(
          nsid: nsid,
          queryItems: [],
          allowsRawResponse: true
        )
        Issue.record("Expected \(nsid) to be rejected")
      } catch TangledError.invalidRequest(let message) {
        #expect(message == "unsupported Bobbin query NSID: \(nsid)")
      } catch {
        Issue.record("Unexpected error: \(error)")
      }
    }
    #expect(await transport.requestCount() == 0)
  }

  @Test func rateLimitUsesCappedRetryAfterThenSucceeds() async throws {
    let sleeper = RecordingSleeper()
    let transport = MockHTTPTransport([
      .response(
        statusCode: 429,
        headers: ["Retry-After": "120"],
        body: try fixture("rate-limit-exceeded")
      ),
      .response(statusCode: 200, body: try fixture("bobbin-coverage-ready")),
    ])
    let client = makeClient(transport: transport, sleeper: sleeper)

    let coverage = try await client.coverage()

    #expect(coverage.ready)
    #expect(await sleeper.recordedDelays() == [60])
    #expect(await transport.requestCount() == 2)
  }

  @Test func rateLimitWithoutRetryAfterUsesRecoveryBackoffThenSucceeds() async throws {
    let sleeper = RecordingSleeper()
    let transport = MockHTTPTransport([
      .response(statusCode: 429, body: try fixture("rate-limit-exceeded")),
      .response(statusCode: 429, body: try fixture("rate-limit-exceeded")),
      .response(statusCode: 200, body: try fixture("bobbin-coverage-ready")),
    ])
    let client = makeClient(transport: transport, sleeper: sleeper)

    let coverage = try await client.coverage()

    #expect(coverage.ready)
    #expect(await sleeper.recordedDelays() == [2, 4])
    #expect(await transport.requestCount() == 3)
  }

  @Test func streamingRateLimitWithoutRetryAfterUsesRecoveryBackoff() async throws {
    let sleeper = RecordingSleeper()
    let transport = MockHTTPTransport([
      .response(statusCode: 429, body: try fixture("rate-limit-exceeded")),
      .response(statusCode: 200, body: Data([1, 2, 3])),
    ])
    let client = makeClient(transport: transport, sleeper: sleeper)

    let archive = try await client.archiveStream(
      repositoryURI: "at://did:plc:owner/sh.tangled.repo/repository",
      ref: "main"
    )
    var iterator = archive.makeAsyncIterator()

    #expect(try await iterator.next() == Data([1, 2, 3]))
    #expect(try await iterator.next() == nil)
    #expect(await sleeper.recordedDelays() == [2])
    #expect(await transport.requestCount() == 2)
  }

  @Test func upstreamFailureRetriesWithExponentialBackoff() async throws {
    let sleeper = RecordingSleeper()
    let transport = MockHTTPTransport([
      .response(statusCode: 502, body: try fixture("upstream-failed")),
      .response(statusCode: 502, body: try fixture("upstream-failed")),
      .response(statusCode: 200, body: try fixture("bobbin-coverage-ready")),
    ])
    let client = makeClient(transport: transport, sleeper: sleeper)

    _ = try await client.coverage()

    #expect(await sleeper.recordedDelays() == [0.25, 0.5])
    #expect(await transport.requestCount() == 3)
  }

  @Test func transientNetworkFailureRetriesThenSucceeds() async throws {
    let sleeper = RecordingSleeper()
    let transport = MockHTTPTransport([
      .failure(URLError(.timedOut)),
      .response(statusCode: 200, body: try fixture("bobbin-coverage-ready")),
    ])
    let client = makeClient(transport: transport, sleeper: sleeper)

    _ = try await client.coverage()

    #expect(await sleeper.recordedDelays() == [0.25])
    #expect(await transport.requestCount() == 2)
  }

  @Test func exhaustedUpstreamFailureMapsToTypedError() async throws {
    let sleeper = RecordingSleeper()
    let body = try fixture("upstream-failed")
    let transport = MockHTTPTransport([
      .response(statusCode: 502, body: body),
      .response(statusCode: 502, body: body),
      .response(statusCode: 502, body: body),
    ])
    let client = makeClient(transport: transport, sleeper: sleeper)

    do {
      _ = try await client.coverage()
      Issue.record("Expected upstreamFailed")
    } catch TangledError.upstreamFailed(let message) {
      #expect(message == "upstream unavailable: slingshot unavailable")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await sleeper.recordedDelays() == [0.25, 0.5])
    #expect(await transport.requestCount() == 3)
  }

  @Test func invalidRequestDoesNotRetryAndPreservesMessage() async throws {
    let sleeper = RecordingSleeper()
    let transport = MockHTTPTransport([
      .response(statusCode: 400, body: try fixture("invalid-request"))
    ])
    let client = makeClient(transport: transport, sleeper: sleeper)

    do {
      _ = try await client.coverage()
      Issue.record("Expected invalidRequest")
    } catch TangledError.invalidRequest(let message) {
      #expect(message == "invalid request: subject must be a bare did")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await sleeper.recordedDelays().isEmpty)
    #expect(await transport.requestCount() == 1)
  }

  @Test func invalidJSONMapsToDecodingError() async {
    let transport = MockHTTPTransport([
      .response(statusCode: 200, body: Data("not-json".utf8))
    ])

    do {
      _ = try await makeClient(transport: transport).coverage()
      Issue.record("Expected decoding error")
    } catch is DecodingError {
      Issue.record("Raw DecodingError escaped")
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func remainingHTTPStatusesMapToTypedErrors() async {
    await expectError(statusCode: 401) { error in
      guard case .unauthorized = error else {
        Issue.record("Expected unauthorized, got \(error)")
        return
      }
    }
    await expectError(
      statusCode: 404,
      body: Data(#"{"error":"RecordNotFound","message":"record not found"}"#.utf8)
    ) { error in
      guard case .notFound(let message) = error else {
        Issue.record("Expected notFound, got \(error)")
        return
      }
      #expect(message == "record not found")
    }
    await expectError(
      statusCode: 429,
      headers: ["Retry-After": "12"],
      body: (try? fixture("rate-limit-exceeded")) ?? Data()
    ) { error in
      guard case .rateLimited(let retryAfter, let message) = error else {
        Issue.record("Expected rateLimited, got \(error)")
        return
      }
      #expect(retryAfter == 12)
      #expect(message == "too many requests, slow down")
    }
    await expectError(
      statusCode: 503,
      body: Data(#"{"error":"Overloaded","message":"overloaded"}"#.utf8)
    ) { error in
      guard case .serviceUnavailable(let message) = error else {
        Issue.record("Expected serviceUnavailable, got \(error)")
        return
      }
      #expect(message == "overloaded")
    }
    await expectError(statusCode: 418) { error in
      guard case .serverStatus(let code, _) = error else {
        Issue.record("Expected serverStatus, got \(error)")
        return
      }
      #expect(code == 418)
    }
  }

  @Test func exhaustedTransientNetworkErrorMapsToNetworkError() async {
    let sleeper = RecordingSleeper()
    let transport = MockHTTPTransport([
      .failure(URLError(.networkConnectionLost)),
      .failure(URLError(.networkConnectionLost)),
      .failure(URLError(.networkConnectionLost)),
    ])
    let client = makeClient(transport: transport, sleeper: sleeper)

    do {
      _ = try await client.coverage()
      Issue.record("Expected network error")
    } catch TangledError.network(let error) {
      #expect(error.code == .networkConnectionLost)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await sleeper.recordedDelays() == [0.25, 0.5])
    #expect(await transport.requestCount() == 3)
  }

  @Test func pageAndCountSummaryAreCodable() throws {
    let page = Page(items: [1, 2], cursor: "next")
    let decoded = try JSONDecoder().decode(Page<Int>.self, from: JSONEncoder().encode(page))
    let count = try JSONDecoder().decode(
      CountSummary.self,
      from: Data(#"{"count":7,"distinctAuthors":3}"#.utf8)
    )

    #expect(decoded == page)
    #expect(count == CountSummary(count: 7, distinctAuthors: 3))
  }
}

extension BobbinClientTests {
  fileprivate func makeClient(
    transport: MockHTTPTransport,
    retryPolicy: BobbinRetryPolicy = .default,
    sleeper: RecordingSleeper = RecordingSleeper()
  ) -> BobbinClient {
    BobbinClient(
      baseURL: URL(string: "https://bobbin.example/base")!,
      transport: transport,
      retryPolicy: retryPolicy,
      sleeper: sleeper
    )
  }

  fileprivate func fixture(_ name: String) throws -> Data {
    guard
      let url = Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
      )
    else {
      throw FixtureError.missing(name)
    }
    return try Data(contentsOf: url)
  }

  fileprivate func expectError(
    statusCode: Int,
    headers: [String: String] = [:],
    body: Data = Data(),
    verify: (TangledError) -> Void
  ) async {
    let transport = MockHTTPTransport([
      .response(statusCode: statusCode, headers: headers, body: body)
    ])
    let client = makeClient(
      transport: transport,
      retryPolicy: BobbinRetryPolicy(maxAttempts: 1)
    )
    do {
      _ = try await client.coverage()
      Issue.record("Expected HTTP error for status \(statusCode)")
    } catch let error as TangledError {
      verify(error)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

private enum FixtureError: Error {
  case missing(String)
}

private actor RecordingSleeper: BobbinSleeping {
  private var delays: [TimeInterval] = []

  func sleep(for delay: TimeInterval) {
    delays.append(delay)
  }

  func recordedDelays() -> [TimeInterval] {
    delays
  }
}

private actor MockHTTPTransport: HTTPTransport {
  enum Outcome: Sendable {
    case response(statusCode: Int, headers: [String: String] = [:], body: Data)
    case failure(URLError)
  }

  private var outcomes: [Outcome]
  private var requests: [URLRequest] = []

  init(_ outcomes: [Outcome]) {
    self.outcomes = outcomes
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    guard !outcomes.isEmpty else {
      throw URLError(.unknown)
    }
    let outcome = outcomes.removeFirst()
    switch outcome {
    case .failure(let error):
      throw error
    case .response(let statusCode, let headers, let body):
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )!
      return (body, response)
    }
  }

  func recordedRequests() -> [URLRequest] {
    requests
  }

  func requestCount() -> Int {
    requests.count
  }
}
