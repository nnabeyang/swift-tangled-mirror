import Foundation
import Testing

@testable import SwiftTangled

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite
struct ArchiveStreamingTests {
  private let repositoryURI = "at://did:plc:owner/sh.tangled.repo/3jzfcijpj2z2a"

  @Test func streamPreservesRequestMetadataAndPullsOnlyOnDemand() async throws {
    let source = ControlledChunkSource([
      Data([0, 1, 2]),
      Data([3, 4, 5]),
    ])
    let transport = StreamingArchiveTransport([
      .init(
        statusCode: 206,
        headers: [
          "Content-Type": "application/gzip",
          "Content-Length": "6",
          "Content-Range": "bytes 10-15/100",
          "Content-Disposition": "attachment; filename=\"repo.tar.gz\"",
          "Accept-Ranges": "bytes",
        ],
        source: source
      )
    ])

    let stream = try await makeClient(transport).archiveStream(
      repositoryURI: repositoryURI,
      ref: "release/v1",
      prefix: "repo-雪",
      byteRange: .bytes(10 ... 15)
    )

    #expect(stream.statusCode == 206)
    #expect(stream.isPartial)
    #expect(stream.contentType == "application/gzip")
    #expect(stream.contentLength == 6)
    #expect(stream.contentRange == "bytes 10-15/100")
    #expect(stream.contentDisposition == "attachment; filename=\"repo.tar.gz\"")
    #expect(stream.acceptRanges == "bytes")
    #expect(source.nextCallCount == 0)

    var iterator = stream.makeAsyncIterator()
    #expect(try await iterator.next() == Data([0, 1, 2]))
    #expect(source.nextCallCount == 1)
    #expect(source.remainingChunkCount == 1)

    stream.cancel()
    #expect(source.wasCancelled)
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.lastPathComponent == "sh.tangled.repo.archive")
    #expect(query("repo", request) == repositoryURI)
    #expect(query("ref", request) == "release/v1")
    #expect(query("format", request) == "tar.gz")
    #expect(query("prefix", request) == "repo-雪")
    #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
    #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-15")
  }

  @Test func writeStreamsToFileAndReplacesDestinationAfterSuccess() async throws {
    let source = ControlledChunkSource([
      Data(repeating: 0xA1, count: 128 * 1024),
      Data(repeating: 0xB2, count: 64 * 1024),
    ])
    let transport = StreamingArchiveTransport([.init(statusCode: 200, source: source)])
    let stream = try await makeClient(transport).archiveStream(
      repositoryURI: repositoryURI,
      ref: "main"
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("repo.tar.gz")
    try Data("old".utf8).write(to: destination)

    let written = try await stream.write(to: destination)

    #expect(written == 192 * 1024)
    #expect(
      try Data(contentsOf: destination)
        == (Data(repeating: 0xA1, count: 128 * 1024)
          + Data(repeating: 0xB2, count: 64 * 1024)))
    #expect(source.nextCallCount == 3)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["repo.tar.gz"]
    )
  }

  @Test func writeFailureKeepsExistingDestinationAndRemovesTemporaryFile() async throws {
    let source = ControlledChunkSource(
      [Data(repeating: 1, count: 1024)],
      trailingError: URLError(.networkConnectionLost)
    )
    let transport = StreamingArchiveTransport([.init(statusCode: 200, source: source)])
    let stream = try await makeClient(transport).archiveStream(
      repositoryURI: repositoryURI,
      ref: "main"
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("repo.tar.gz")
    let original = Data("keep".utf8)
    try original.write(to: destination)

    do {
      _ = try await stream.write(to: destination)
      Issue.record("Expected network failure")
    } catch TangledError.network(let error) {
      #expect(error.code == .networkConnectionLost)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(try Data(contentsOf: destination) == original)
    #expect(source.wasCancelled)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["repo.tar.gz"]
    )
  }

  @Test func responseFailureRetriesBeforeReturningStream() async throws {
    let failure = ControlledChunkSource([
      Data(#"{"error":"UpstreamFailed","message":"warming"}"#.utf8)
    ])
    let success = ControlledChunkSource([Data([7, 8, 9])])
    let transport = StreamingArchiveTransport([
      .init(statusCode: 502, source: failure),
      .init(statusCode: 200, source: success),
    ])
    let client = BobbinClient(
      baseURL: URL(string: "https://bobbin.example/base")!,
      transport: transport,
      retryPolicy: BobbinRetryPolicy(maxAttempts: 2, baseDelay: 0)
    )

    let stream = try await client.archiveStream(repositoryURI: repositoryURI, ref: "main")
    var content = Data()
    for try await chunk in stream {
      content.append(chunk)
    }

    #expect(content == Data([7, 8, 9]))
    #expect(await transport.requestCount() == 2)
    #expect(failure.nextCallCount == 2)
  }

  @Test func nonRetryableResponseUsesTypedErrorAndBoundsErrorBody() async {
    let oversizedMessage = String(repeating: "x", count: 128 * 1024)
    let source = ControlledChunkSource([
      Data(#"{"error":"RepoNotFound","message":""#.utf8),
      Data(oversizedMessage.utf8),
      Data(#""}"#.utf8),
    ])
    let transport = StreamingArchiveTransport([
      .init(statusCode: 404, source: source)
    ])

    do {
      _ = try await makeClient(transport).archiveStream(
        repositoryURI: repositoryURI,
        ref: "main"
      )
      Issue.record("Expected notFound")
    } catch TangledError.notFound {
      #expect(source.wasCancelled)
      #expect(source.nextCallCount == 2)
      #expect(source.remainingChunkCount == 1)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func midstreamNetworkFailureIsMappedWithoutRetry() async throws {
    let source = ControlledChunkSource(
      [Data([1, 2, 3])],
      trailingError: URLError(.networkConnectionLost)
    )
    let transport = StreamingArchiveTransport([.init(statusCode: 200, source: source)])
    let stream = try await makeClient(transport).archiveStream(
      repositoryURI: repositoryURI,
      ref: "main"
    )

    do {
      for try await _ in stream {}
      Issue.record("Expected network failure")
    } catch TangledError.network(let error) {
      #expect(error.code == .networkConnectionLost)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(await transport.requestCount() == 1)
    #expect(source.wasCancelled)
  }

  @Test func taskCancellationCancelsUnderlyingStream() async throws {
    let source = ControlledChunkSource([], blocksAtEnd: true)
    let transport = StreamingArchiveTransport([.init(statusCode: 200, source: source)])
    let stream = try await makeClient(transport).archiveStream(
      repositoryURI: repositoryURI,
      ref: "main"
    )
    let task = Task {
      for try await _ in stream {}
    }
    while source.nextCallCount == 0 {
      await Task.yield()
    }

    task.cancel()
    do {
      try await task.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(source.wasCancelled)
  }

  @Test func invalidStreamInputsFailBeforeRequest() async {
    let transport = StreamingArchiveTransport([])
    do {
      _ = try await makeClient(transport).archiveStream(
        repositoryURI: repositoryURI,
        ref: "",
        byteRange: .suffix(0)
      )
      Issue.record("Expected invalidRequest")
    } catch TangledError.invalidRequest {
      #expect(await transport.requestCount() == 0)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  private func makeClient(_ transport: StreamingArchiveTransport) -> BobbinClient {
    BobbinClient(
      baseURL: URL(string: "https://bobbin.example/base")!,
      transport: transport,
      retryPolicy: BobbinRetryPolicy(maxAttempts: 1)
    )
  }

  private func query(_ name: String, _ request: URLRequest) -> String? {
    guard let url = request.url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == name }?.value
  }
}

private final class ControlledChunkSource: @unchecked Sendable {
  private let lock = NSLock()
  private var chunks: [Data]
  private var trailingError: (any Error)?
  private let blocksAtEnd: Bool
  private var calls = 0
  private var cancelled = false

  init(
    _ chunks: [Data],
    trailingError: (any Error)? = nil,
    blocksAtEnd: Bool = false
  ) {
    self.chunks = chunks
    self.trailingError = trailingError
    self.blocksAtEnd = blocksAtEnd
  }

  var nextCallCount: Int { lock.withLock { calls } }
  var remainingChunkCount: Int { lock.withLock { chunks.count } }
  var wasCancelled: Bool { lock.withLock { cancelled } }

  func next() async throws -> Data? {
    let result: Result<Data?, any Error>? = lock.withLock {
      calls += 1
      if cancelled { return .failure(CancellationError()) }
      if !chunks.isEmpty { return .success(chunks.removeFirst()) }
      if let trailingError {
        self.trailingError = nil
        return .failure(trailingError)
      }
      return blocksAtEnd ? nil : .success(nil)
    }
    if let result {
      return try result.get()
    }
    try await Task.sleep(for: .seconds(60))
    return nil
  }

  func cancel() {
    lock.withLock {
      cancelled = true
    }
  }
}

private actor StreamingArchiveTransport: HTTPTransport {
  struct Response: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let source: ControlledChunkSource

    init(
      statusCode: Int,
      headers: [String: String] = [:],
      source: ControlledChunkSource
    ) {
      self.statusCode = statusCode
      self.headers = headers
      self.source = source
    }
  }

  private var responses: [Response]
  private var requests: [URLRequest] = []

  init(_ responses: [Response]) {
    self.responses = responses
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw TangledError.transport("Streaming test unexpectedly used buffered transport")
  }

  func sendStreaming(_ request: URLRequest) async throws -> (HTTPBodyStream, HTTPURLResponse) {
    requests.append(request)
    guard !responses.isEmpty else { throw URLError(.unknown) }
    let response = responses.removeFirst()
    return (
      HTTPBodyStream(
        unfolding: { try await response.source.next() },
        onCancel: { response.source.cancel() }
      ),
      HTTPURLResponse(
        url: request.url!,
        statusCode: response.statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: response.headers
      )!
    )
  }

  func recordedRequests() -> [URLRequest] { requests }
  func requestCount() -> Int { requests.count }
}
