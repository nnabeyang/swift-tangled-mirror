import Foundation
import Testing

@testable import SwiftTangled

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite(.serialized)
struct HTTPBodyStreamStorageTests {
  @Test func boundsBufferedDataAndSuspendsUntilDemand() async throws {
    let storage = HTTPBodyStreamStorage()
    let task = RecordingTaskController()
    let session = RecordingSessionController()
    storage.attach(taskController: task, sessionController: session)

    storage.receive(Data([1]))
    #expect(task.suspendCount == 1)

    let secondReceiveStarted = DispatchSemaphore(value: 0)
    let secondReceiveFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      secondReceiveStarted.signal()
      storage.receive(Data([2]))
      secondReceiveFinished.signal()
    }
    #expect(
      await wait(for: secondReceiveStarted, timeout: .now() + 1) == .success
    )
    let initiallyBlocked = await wait(
      for: secondReceiveFinished,
      timeout: .now() + 0.05
    )
    #expect(initiallyBlocked == .timedOut)

    #expect(try await storage.next() == Data([1]))
    let eventuallyFinished = await wait(
      for: secondReceiveFinished,
      timeout: .now() + 1
    )
    #expect(eventuallyFinished == .success)
    #expect(task.resumeCount == 1)
    #expect(task.suspendCount == 2)

    #expect(try await storage.next() == Data([2]))
    storage.finish()
    #expect(try await storage.next() == nil)
    #expect(task.resumeCount == 2)
    #expect(session.finishCount == 1)
    #expect(session.cancelCount == 0)
  }

  @Test func explicitCancellationReleasesWaitingContinuationTaskAndSession() async {
    let storage = HTTPBodyStreamStorage()
    let task = RecordingTaskController()
    let session = RecordingSessionController()
    storage.attach(taskController: task, sessionController: session)
    let consumer = Task { try await storage.next() }
    await Task.yield()

    storage.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await consumer.value
    }
    #expect(task.cancelCount == 1)
    #expect(session.cancelCount == 1)
    #expect(session.finishCount == 0)
  }

  @Test func taskCancellationCancelsTaskAndSession() async {
    let storage = HTTPBodyStreamStorage()
    let task = RecordingTaskController()
    let session = RecordingSessionController()
    storage.attach(taskController: task, sessionController: session)
    let consumer = Task { try await storage.next() }
    await Task.yield()

    consumer.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await consumer.value
    }
    #expect(task.cancelCount == 1)
    #expect(session.cancelCount == 1)
  }

  @Test func networkFailureReleasesSessionAndReachesConsumer() async {
    let storage = HTTPBodyStreamStorage()
    let task = RecordingTaskController()
    let session = RecordingSessionController()
    storage.attach(taskController: task, sessionController: session)
    let consumer = Task { try await storage.next() }
    await Task.yield()
    let failure = URLError(.networkConnectionLost)

    storage.finish(error: failure)

    do {
      _ = try await consumer.value
      Issue.record("Expected network failure")
    } catch let error as URLError {
      #expect(error.code == .networkConnectionLost)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(task.cancelCount == 0)
    #expect(session.finishCount == 1)
  }
}

private func wait(
  for semaphore: DispatchSemaphore,
  timeout: DispatchTime
) async -> DispatchTimeoutResult {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: semaphore.wait(timeout: timeout))
    }
  }
}

@Suite(.serialized)
struct URLSessionTransportStreamingTests {
  private let repositoryURI = "at://did:plc:owner/sh.tangled.repo/3jzfcijpj2z2a"

  @Test func streamsMultipleChunksAndPreservesResponseMetadata() async throws {
    let endpoint = StreamingProtocolEndpoint([
      .init(
        statusCode: 200,
        headers: [
          "Content-Type": "application/gzip",
          "Content-Length": "6",
          "Accept-Ranges": "bytes",
        ],
        chunks: [Data([0, 1, 2]), Data([3, 4, 5])]
      )
    ])
    let (client, registration) = makeClient(endpoint)
    defer { registration.remove() }

    let stream = try await client.archiveStream(repositoryURI: repositoryURI, ref: "main")
    var received = Data()
    for try await chunk in stream {
      received.append(chunk)
      await Task.yield()
    }

    #expect(received == Data([0, 1, 2, 3, 4, 5]))
    #expect(stream.statusCode == 200)
    #expect(stream.contentType == "application/gzip")
    #expect(stream.contentLength == 6)
    #expect(stream.acceptRanges == "bytes")
  }

  @Test func sendsRangeAndReturnsPartialResponseMetadata() async throws {
    let endpoint = StreamingProtocolEndpoint([
      .init(
        statusCode: 206,
        headers: [
          "Content-Length": "3",
          "Content-Range": "bytes 10-12/100",
        ],
        chunks: [Data([10, 11, 12])]
      )
    ])
    let (client, registration) = makeClient(endpoint)
    defer { registration.remove() }

    let stream = try await client.archiveStream(
      repositoryURI: repositoryURI,
      ref: "release/v1",
      byteRange: .bytes(10 ... 12)
    )
    var iterator = stream.makeAsyncIterator()

    #expect(try await iterator.next() == Data([10, 11, 12]))
    #expect(try await iterator.next() == nil)
    #expect(stream.statusCode == 206)
    #expect(stream.isPartial)
    #expect(stream.contentRange == "bytes 10-12/100")
    #expect(endpoint.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=10-12")
  }

  @Test func maps404And416Responses() async {
    let notFoundEndpoint = StreamingProtocolEndpoint([
      .init(
        statusCode: 404,
        chunks: [Data(#"{"error":"RepoNotFound","message":"missing"}"#.utf8)]
      )
    ])
    let (notFoundClient, notFoundRegistration) = makeClient(notFoundEndpoint)
    defer { notFoundRegistration.remove() }

    do {
      _ = try await notFoundClient.archiveStream(repositoryURI: repositoryURI, ref: "main")
      Issue.record("Expected notFound")
    } catch TangledError.notFound(let message) {
      #expect(message == "missing")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let rangeEndpoint = StreamingProtocolEndpoint([
      .init(
        statusCode: 416,
        chunks: [Data(#"{"error":"RangeNotSatisfiable","message":"outside archive"}"#.utf8)]
      )
    ])
    let (rangeClient, rangeRegistration) = makeClient(rangeEndpoint)
    defer { rangeRegistration.remove() }

    do {
      _ = try await rangeClient.archiveStream(
        repositoryURI: repositoryURI,
        ref: "main",
        byteRange: .from(999)
      )
      Issue.record("Expected serverStatus")
    } catch TangledError.serverStatus(let status, let message) {
      #expect(status == 416)
      #expect(message == "outside archive")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func retries502BeforeReturningStream() async throws {
    let endpoint = StreamingProtocolEndpoint([
      .init(
        statusCode: 502,
        chunks: [Data(#"{"error":"UpstreamFailed","message":"warming"}"#.utf8)]
      ),
      .init(statusCode: 200, chunks: [Data([7, 8, 9])]),
    ])
    let (client, registration) = makeClient(endpoint, maxAttempts: 2)
    defer { registration.remove() }

    let stream = try await client.archiveStream(repositoryURI: repositoryURI, ref: "main")
    var iterator = stream.makeAsyncIterator()

    #expect(try await iterator.next() == Data([7, 8, 9]))
    #expect(try await iterator.next() == nil)
    #expect(endpoint.requests.count == 2)
  }

  private func makeClient(
    _ endpoint: StreamingProtocolEndpoint,
    maxAttempts: Int = 1
  ) -> (BobbinClient, StreamingProtocolRegistration) {
    let host = "stream-\(UUID().uuidString.lowercased()).example"
    let baseURL = URL(string: "https://\(host)")!
    let registration = StreamingTestURLProtocol.register(endpoint, forHost: host)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamingTestURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return (
      BobbinClient(
        baseURL: baseURL,
        transport: URLSessionTransport(session: session),
        retryPolicy: BobbinRetryPolicy(maxAttempts: maxAttempts, baseDelay: 0)
      ),
      registration
    )
  }
}

private final class RecordingTaskController: HTTPBodyStreamTaskControlling,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var suspends = 0
  private var resumes = 0
  private var cancellations = 0

  var suspendCount: Int { lock.withLock { suspends } }
  var resumeCount: Int { lock.withLock { resumes } }
  var cancelCount: Int { lock.withLock { cancellations } }

  func suspend() {
    lock.withLock { suspends += 1 }
  }

  func resume() {
    lock.withLock { resumes += 1 }
  }

  func cancel() {
    lock.withLock { cancellations += 1 }
  }
}

private final class RecordingSessionController: HTTPBodyStreamSessionControlling,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var finishes = 0
  private var cancellations = 0

  var finishCount: Int { lock.withLock { finishes } }
  var cancelCount: Int { lock.withLock { cancellations } }

  func finish() {
    lock.withLock { finishes += 1 }
  }

  func cancel() {
    lock.withLock { cancellations += 1 }
  }
}

private final class StreamingProtocolEndpoint: @unchecked Sendable {
  struct Response: Sendable {
    enum Ending: Sendable {
      case finish
    }

    let statusCode: Int
    let headers: [String: String]
    let chunks: [Data]
    let ending: Ending

    init(
      statusCode: Int,
      headers: [String: String] = [:],
      chunks: [Data] = [],
      ending: Ending = .finish
    ) {
      self.statusCode = statusCode
      self.headers = headers
      self.chunks = chunks
      self.ending = ending
    }
  }

  private let condition = NSCondition()
  private var responses: [Response]
  private var recordedRequests: [URLRequest] = []

  init(_ responses: [Response]) {
    self.responses = responses
  }

  var requests: [URLRequest] {
    condition.withLock { recordedRequests }
  }

  func nextResponse(for request: URLRequest) -> Response? {
    condition.withLock {
      recordedRequests.append(request)
      guard !responses.isEmpty else { return nil }
      return responses.removeFirst()
    }
  }

}

private struct StreamingProtocolRegistration {
  let host: String

  func remove() {
    StreamingTestURLProtocol.remove(host: host)
  }
}

private final class StreamingTestURLProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var endpoints: [String: StreamingProtocolEndpoint] = [:]

  static func register(
    _ endpoint: StreamingProtocolEndpoint,
    forHost host: String
  ) -> StreamingProtocolRegistration {
    lock.withLock {
      endpoints[host] = endpoint
    }
    return StreamingProtocolRegistration(host: host)
  }

  static func remove(host: String) {
    _ = lock.withLock {
      endpoints.removeValue(forKey: host)
    }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    endpoint(for: request) != nil
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let endpoint = Self.endpoint(for: request),
      let response = endpoint.nextResponse(for: request),
      let url = request.url,
      let httpResponse = HTTPURLResponse(
        url: url,
        statusCode: response.statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: response.headers
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
    for chunk in response.chunks {
      client?.urlProtocol(self, didLoad: chunk)
    }
    switch response.ending {
    case .finish:
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}

  private static func endpoint(for request: URLRequest) -> StreamingProtocolEndpoint? {
    guard let host = request.url?.host else { return nil }
    return lock.withLock { endpoints[host] }
  }
}
