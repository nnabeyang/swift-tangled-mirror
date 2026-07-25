import Foundation
import Testing

@testable import SwiftTangled

@Suite struct JetstreamClientTests {
  @Test func decodesCommitIdentityAccountAndUnknownValues() throws {
    let decoder = JSONDecoder()
    let commit = try decoder.decode(
      TangledEvent.self,
      from: eventData(
        timeUS: 100,
        kind: "commit",
        payload:
          #""commit":{"rev":"3rev","operation":"future","collection":"sh.tangled.repo.pull","rkey":"3key","record":{"$type":"sh.tangled.repo.pull","title":"Test"},"cid":"bafy"}"#
      )
    )
    #expect(commit.kind == .commit)
    #expect(commit.commit?.operation.rawValue == "future")
    #expect(
      commit.commit?.record
        == .object([
          "$type": .string("sh.tangled.repo.pull"),
          "title": .string("Test"),
        ])
    )

    let identity = try decoder.decode(
      TangledEvent.self,
      from: eventData(
        timeUS: 101,
        kind: "identity",
        payload:
          #""identity":{"did":"did:plc:example","handle":"example.test","seq":1,"time":"2026-07-24T00:00:00Z"}"#
      )
    )
    #expect(identity.identity?.handle == "example.test")

    let account = try decoder.decode(
      TangledEvent.self,
      from: eventData(
        timeUS: 102,
        kind: "account",
        payload:
          #""account":{"active":false,"did":"did:plc:example","seq":2,"time":"2026-07-24T00:00:01Z","status":"deactivated"}"#
      )
    )
    #expect(account.account?.status == "deactivated")

    let unknown = try decoder.decode(
      TangledEvent.self,
      from: eventData(timeUS: 103, kind: "future", payload: "")
    )
    #expect(unknown.kind.rawValue == "future")
  }

  @Test func buildsFilteredSubscriptionURL() async throws {
    let connector = JetstreamConnectorMock(steps: [
      .messages([eventData(timeUS: 200)]),
      .wait,
    ])
    let client = makeClient(connector: connector)
    let consumer = Task {
      for try await event in client.events(
        options: JetstreamOptions(
          wantedCollections: ["sh.tangled.repo.pull", "sh.tangled.ci.pipeline"],
          wantedDIDs: ["did:plc:example"],
          cursor: 123,
          maxMessageSizeBytes: 4096
        )
      ) {
        return event
      }
      throw CancellationError()
    }
    #expect(try await consumer.value.timeUS == 200)
    consumer.cancel()

    let url = try #require(await connector.urls().first)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(
      components.queryItems?.filter { $0.name == "wantedCollections" }.map(\.value) == [
        "sh.tangled.repo.pull", "sh.tangled.ci.pipeline",
      ])
    #expect(components.queryItems?.first { $0.name == "wantedDids" }?.value == "did:plc:example")
    #expect(components.queryItems?.first { $0.name == "cursor" }?.value == "123")
    #expect(components.queryItems?.first { $0.name == "maxMessageSizeBytes" }?.value == "4096")
  }

  @Test func reconnectsWithRewoundCursorAndDropsDuplicateEvents() async throws {
    let first = eventData(timeUS: 10_000_000)
    let second = eventData(timeUS: 10_000_001)
    let connector = JetstreamConnectorMock(steps: [
      .messagesThenFailure([first]),
      .messages([first, second]),
      .wait,
    ])
    let sleeper = JetstreamSleeperMock()
    let states = ConnectionStates()
    let client = makeClient(
      connector: connector,
      sleeper: sleeper,
      stateHandler: { states.append($0) }
    )

    let consumer = Task {
      var values: [TangledEvent] = []
      for try await event in client.events() {
        values.append(event)
        if values.count == 2 { return values }
      }
      return values
    }
    let values = try await consumer.value
    consumer.cancel()

    #expect(values.map(\.timeUS) == [10_000_000, 10_000_001])
    #expect(await sleeper.delays() == [0.25, 0.25])
    let urls = await connector.urls()
    #expect(urls.count >= 2)
    let reconnectURL = try #require(URLComponents(url: urls[1], resolvingAgainstBaseURL: false))
    #expect(reconnectURL.queryItems?.first { $0.name == "cursor" }?.value == "5000000")
    #expect(
      states.values().contains { state in
        if case .reconnecting(_, let attempt, let delay, _) = state {
          return attempt == 1 && delay == 0.25
        }
        return false
      })
  }

  @Test func invalidOptionsAndMalformedJSONTerminateStream() async {
    let client = makeClient(connector: JetstreamConnectorMock(steps: []))
    await #expect(throws: TangledError.self) {
      for try await _ in client.events(options: JetstreamOptions(cursor: -1)) {}
    }

    let malformed = makeClient(
      connector: JetstreamConnectorMock(steps: [.messages([Data("not json".utf8)])])
    )
    await #expect(throws: TangledError.self) {
      for try await _ in malformed.events() {}
    }
  }

  @Test func cancellingConsumerStopsActiveConnection() async throws {
    let connector = JetstreamConnectorMock(steps: [.wait])
    let client = makeClient(connector: connector)
    let consumer = Task {
      for try await _ in client.events() {}
    }
    while await connector.urls().isEmpty {
      await Task.yield()
    }

    consumer.cancel()
    try await consumer.value
    for _ in 0 ..< 100 where await connector.cancellations() == 0 {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await connector.cancellations() == 1)
  }

  private func makeClient(
    connector: JetstreamConnectorMock,
    sleeper: JetstreamSleeperMock = JetstreamSleeperMock(),
    stateHandler: @escaping @Sendable (JetstreamConnectionState) -> Void = { _ in }
  ) -> JetstreamClient {
    JetstreamClient(
      endpoint: URL(string: "wss://jetstream.example/subscribe")!,
      retryPolicy: .default,
      connector: connector,
      sleeper: sleeper,
      onConnectionStateChange: stateHandler
    )
  }

  private func eventData(
    timeUS: Int64,
    kind: String = "commit",
    payload: String? = nil
  ) -> Data {
    let resolvedPayload =
      payload
      ?? #""commit":{"rev":"3rev","operation":"create","collection":"sh.tangled.repo.pull","rkey":"3key","record":{"title":"Test"},"cid":"bafy"}"#
    let suffix = resolvedPayload.isEmpty ? "" : ",\(resolvedPayload)"
    return Data(
      #"{"did":"did:plc:example","time_us":\#(timeUS),"kind":"\#(kind)"\#(suffix)}"#.utf8
    )
  }
}

@Suite struct JetstreamLiveTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["SWIFT_TANGLED_LIVE_JETSTREAM"] == "1"
    )
  )
  func connectsToPublicJetstreamAndCancelsCleanly() async throws {
    let states = ConnectionStates()
    let client = JetstreamClient(onConnectionStateChange: { states.append($0) })
    let consumer = Task {
      for try await _ in client.events() {}
    }

    for _ in 0 ..< 200 {
      if states.values().contains(where: {
        if case .connected = $0 { return true }
        return false
      }) {
        consumer.cancel()
        try await consumer.value
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    consumer.cancel()
    try? await consumer.value
    Issue.record("Jetstream did not connect within 10 seconds")
  }
}

private actor JetstreamConnectorMock: JetstreamConnecting {
  enum Step: Sendable {
    case messages([Data])
    case messagesThenFailure([Data])
    case wait
  }

  private var steps: [Step]
  private var recordedURLs: [URL] = []
  private var cancellationCount = 0

  init(steps: [Step]) {
    self.steps = steps
  }

  func connect(
    url: URL,
    maxMessageSize: Int,
    onConnected: @escaping @Sendable () -> Void,
    onMessage: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    recordedURLs.append(url)
    onConnected()
    guard !steps.isEmpty else {
      try await Task.sleep(for: .seconds(60))
      return
    }
    let step = steps.removeFirst()
    do {
      switch step {
      case .messages(let messages):
        for message in messages {
          try await onMessage(message)
        }
      case .messagesThenFailure(let messages):
        for message in messages {
          try await onMessage(message)
        }
        throw URLError(.networkConnectionLost)
      case .wait:
        try await Task.sleep(for: .seconds(60))
      }
    } catch is CancellationError {
      cancellationCount += 1
      throw CancellationError()
    }
  }

  func urls() -> [URL] {
    recordedURLs
  }

  func cancellations() -> Int {
    cancellationCount
  }
}

private actor JetstreamSleeperMock: JetstreamSleeping {
  private var recordedDelays: [TimeInterval] = []

  func sleep(for delay: TimeInterval) {
    recordedDelays.append(delay)
  }

  func delays() -> [TimeInterval] {
    recordedDelays
  }
}

private final class ConnectionStates: @unchecked Sendable {
  private let lock = NSLock()
  private var states: [JetstreamConnectionState] = []

  func append(_ state: JetstreamConnectionState) {
    lock.withLock { states.append(state) }
  }

  func values() -> [JetstreamConnectionState] {
    lock.withLock { states }
  }
}
