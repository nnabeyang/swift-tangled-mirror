import Foundation
import SwiftAtproto
import TangledLexicons
import Testing

@testable import SwiftTangled

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct PipelineLogAPITests {
  @Test func preparesSubscriptionURLAndDeduplicatesWorkflows() async throws {
    let http = PipelineLogHTTPTransport(body: pipelineFixture)
    let subscription = RecordingSubscriptionTransport()
    let client = SpindleClient(
      baseURL: URL(string: "https://spindle.example/base")!,
      transport: http,
      subscriptionTransport: subscription,
      retryPolicy: BobbinRetryPolicy(maxAttempts: 1)
    )

    let events = try await client.pipelineLogs(
      pipelineID: pipelineID,
      workflows: ["build.yml", "build.yml"]
    )
    for try await _ in events {}

    let request = try #require(await subscription.request())
    #expect(request.url.scheme == "wss")
    #expect(request.url.path == "/base/xrpc/sh.tangled.ci.subscribePipelineLogs")
    let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.filter { $0.name == "pipeline" }.map(\.value) == [pipelineID])
    #expect(query.filter { $0.name == "workflows" }.map(\.value) == ["build.yml"])
    #expect(await http.requestCount() == 1)
    #expect(client.subscriptionConfiguration.bufferCapacity == 4_096)
  }

  @Test func omitsWorkflowQueryWhenEveryWorkflowIsSelected() async throws {
    let subscription = RecordingSubscriptionTransport()
    let client = SpindleClient(
      baseURL: URL(string: "http://spindle.example")!,
      transport: PipelineLogHTTPTransport(body: pipelineFixture),
      subscriptionTransport: subscription,
      retryPolicy: BobbinRetryPolicy(maxAttempts: 1)
    )

    let events = try await client.pipelineLogs(pipelineID: pipelineID)
    for try await _ in events {}

    let request = try #require(await subscription.request())
    #expect(request.url.scheme == "ws")
    let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.filter { $0.name == "pipeline" }.map(\.value) == [pipelineID])
    #expect(query.allSatisfy { $0.name != "workflows" })
  }

  @Test func validatesPipelineAndWorkflowBeforeConnecting() async {
    let subscription = RecordingSubscriptionTransport()
    let http = PipelineLogHTTPTransport(body: pipelineFixture)
    let client = SpindleClient(
      baseURL: URL(string: "https://spindle.example")!,
      transport: http,
      subscriptionTransport: subscription,
      retryPolicy: BobbinRetryPolicy(maxAttempts: 1)
    )

    await expectInvalidRequest {
      _ = try await client.pipelineLogs(pipelineID: "not-a-tid")
    }
    #expect(await http.requestCount() == 0)

    await expectInvalidRequest {
      _ = try await client.pipelineLogs(pipelineID: pipelineID, workflows: [""])
    }
    await expectInvalidRequest {
      _ = try await client.pipelineLogs(
        pipelineID: pipelineID,
        workflows: ["missing.yml"]
      )
    }
    #expect(await subscription.request() == nil)
  }

  @Test func mapsGeneratedControlAndDataMessages() throws {
    let client = SpindleClient(baseURL: URL(string: "https://spindle.example")!)
    let time = FormatString<Date>(rawValue: "2026-07-30T12:00:00Z")

    let control = client.pipelineLogEvent(
      from: .ciSubscribePipelineLogsControl(
        .init(
          command: "swift test",
          content: "Run tests",
          kind: .user,
          status: .start,
          step: 2,
          time: time,
          workflow: "build.yml"
        )
      )
    )
    #expect(
      control
        == .control(
          PipelineLogControl(
            time: time,
            workflow: "build.yml",
            step: 2,
            content: "Run tests",
            command: "swift test",
            status: .start,
            kind: .user
          )
        )
    )

    let data = client.pipelineLogEvent(
      from: .ciSubscribePipelineLogsData(
        .init(
          content: "done\n",
          step: 2,
          stream: .stderr,
          time: time,
          workflow: "build.yml"
        )
      )
    )
    #expect(
      data
        == .data(
          PipelineLogData(
            time: time,
            workflow: "build.yml",
            step: 2,
            content: "done\n",
            stream: .stderr
          )
        )
    )
  }

  @Test func pipelineLogJSONUsesStableFlatShape() throws {
    let event = PipelineLogEvent.data(
      PipelineLogData(
        time: FormatString<Date>(rawValue: "2026-07-30T12:00:00Z"),
        workflow: "build.yml",
        step: 3,
        content: "hello\n",
        stream: .stdout
      )
    )
    let data = try JSONEncoder().encode(event)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["type"] as? String == "data")
    #expect(object["time"] as? String == "2026-07-30T12:00:00Z")
    #expect(object["workflow"] as? String == "build.yml")
    #expect(object["step"] as? Int == 3)
    #expect(object["content"] as? String == "hello\n")
    #expect(object["stream"] as? String == "stdout")
    #expect(try JSONDecoder().decode(PipelineLogEvent.self, from: data) == event)
  }

  private func expectInvalidRequest(_ operation: () async throws -> Void) async {
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

private let pipelineID = "3mr7m2f6ger22"

private let pipelineFixture = Data(
  """
  {
    "id": "\(pipelineID)",
    "repo": "did:plc:repository",
    "commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "trigger": {
      "$type": "sh.tangled.ci.trigger#manual",
      "sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    "workflows": [
      {
        "id": "build.yml",
        "name": "build.yml",
        "status": "success"
      }
    ]
  }
  """.utf8
)

private actor PipelineLogHTTPTransport: HTTPTransport {
  private let body: Data
  private var count = 0

  init(body: Data) {
    self.body = body
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    count += 1
    return (
      body,
      HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: [:]
      )!
    )
  }

  func requestCount() -> Int {
    count
  }
}

private actor RecordingSubscriptionTransport: XRPCSubscriptionTransport {
  private var recordedRequest: XRPCWebSocketRequest?

  func connect(_ request: XRPCWebSocketRequest) async throws -> XRPCWebSocketConnection {
    recordedRequest = request
    return XRPCWebSocketConnection(
      messages: AsyncThrowingStream { continuation in
        continuation.finish()
      },
      close: {}
    )
  }

  func request() -> XRPCWebSocketRequest? {
    recordedRequest
  }
}
