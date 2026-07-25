import Foundation
import Logging
import WSClient

public struct JetstreamOptions: Equatable, Sendable {
  public let wantedCollections: [String]
  public let wantedDIDs: [String]
  public let cursor: Int64?
  public let maxMessageSizeBytes: Int

  public init(
    wantedCollections: [String] = ["sh.tangled.*"],
    wantedDIDs: [String] = [],
    cursor: Int64? = nil,
    maxMessageSizeBytes: Int = 1 << 20
  ) {
    self.wantedCollections = wantedCollections
    self.wantedDIDs = wantedDIDs
    self.cursor = cursor
    self.maxMessageSizeBytes = maxMessageSizeBytes
  }
}

public struct JetstreamRetryPolicy: Equatable, Sendable {
  public let baseDelay: TimeInterval
  public let maximumDelay: TimeInterval
  public let cursorRewind: Int64
  public let deduplicationWindow: Int64
  public let maximumRememberedEvents: Int

  public init(
    baseDelay: TimeInterval = 0.25,
    maximumDelay: TimeInterval = 30,
    cursorRewind: Int64 = 5_000_000,
    deduplicationWindow: Int64 = 10_000_000,
    maximumRememberedEvents: Int = 10_000
  ) {
    self.baseDelay = max(0, baseDelay)
    self.maximumDelay = max(0, maximumDelay)
    self.cursorRewind = max(0, cursorRewind)
    self.deduplicationWindow = max(0, deduplicationWindow)
    self.maximumRememberedEvents = max(1, maximumRememberedEvents)
  }

  public static let `default` = JetstreamRetryPolicy()
}

public enum JetstreamConnectionState: Equatable, Sendable {
  case connecting(cursor: Int64?)
  case connected(cursor: Int64?)
  case reconnecting(cursor: Int64?, attempt: Int, delay: TimeInterval, reason: String)
}

public struct JetstreamClient: Sendable {
  public static let defaultEndpoint = URL(
    string: "wss://jetstream1.us-east.bsky.network/subscribe"
  )!

  public let endpoint: URL
  public let retryPolicy: JetstreamRetryPolicy

  private let connector: any JetstreamConnecting
  private let sleeper: any JetstreamSleeping
  private let stateHandler: @Sendable (JetstreamConnectionState) -> Void

  public init(
    endpoint: URL = JetstreamClient.defaultEndpoint,
    retryPolicy: JetstreamRetryPolicy = .default,
    onConnectionStateChange: @escaping @Sendable (JetstreamConnectionState) -> Void = { _ in }
  ) {
    self.init(
      endpoint: endpoint,
      retryPolicy: retryPolicy,
      connector: WebSocketJetstreamConnector(),
      sleeper: TaskJetstreamSleeper(),
      onConnectionStateChange: onConnectionStateChange
    )
  }

  init(
    endpoint: URL,
    retryPolicy: JetstreamRetryPolicy,
    connector: any JetstreamConnecting,
    sleeper: any JetstreamSleeping,
    onConnectionStateChange: @escaping @Sendable (JetstreamConnectionState) -> Void = { _ in }
  ) {
    self.endpoint = endpoint
    self.retryPolicy = retryPolicy
    self.connector = connector
    self.sleeper = sleeper
    self.stateHandler = onConnectionStateChange
  }

  public func events(
    options: JetstreamOptions = JetstreamOptions()
  ) -> AsyncThrowingStream<TangledEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try validate(options)
          try await run(options: options, continuation: continuation)
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

protocol JetstreamConnecting: Sendable {
  func connect(
    url: URL,
    maxMessageSize: Int,
    onConnected: @escaping @Sendable () -> Void,
    onMessage: @escaping @Sendable (Data) async throws -> Void
  ) async throws
}

protocol JetstreamSleeping: Sendable {
  func sleep(for delay: TimeInterval) async throws
}

private struct TaskJetstreamSleeper: JetstreamSleeping {
  func sleep(for delay: TimeInterval) async throws {
    guard delay > 0 else { return }
    try await Task.sleep(for: .seconds(delay))
  }
}

private struct WebSocketJetstreamConnector: JetstreamConnecting {
  func connect(
    url: URL,
    maxMessageSize: Int,
    onConnected: @escaping @Sendable () -> Void,
    onMessage: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    do {
      try await WebSocketClient.connect(
        url: url.absoluteString,
        configuration: .init(
          maxFrameSize: min(maxMessageSize, 1 << 20),
          autoPing: .enabled(timePeriod: .seconds(30)),
          validateUTF8: true
        ),
        logger: Logger(label: "SwiftTangled.Jetstream")
      ) { inbound, _, _ in
        onConnected()
        for try await message in inbound.messages(maxSize: maxMessageSize) {
          switch message {
          case .text(let text):
            try await onMessage(Data(text.utf8))
          case .binary:
            throw TangledError.invalidRequest(
              "Jetstream returned a binary message; compressed streams are not supported"
            )
          }
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TangledError {
      throw error
    } catch let error as WebSocketClientError {
      if error == .serverSentMessageTooLarge {
        throw TangledError.invalidRequest("Jetstream message exceeded maxMessageSizeBytes")
      }
      throw TangledError.transport(String(describing: error))
    } catch {
      throw TangledError.transport(String(describing: error))
    }
  }
}

extension JetstreamClient {
  private func run(
    options: JetstreamOptions,
    continuation: AsyncThrowingStream<TangledEvent, any Error>.Continuation
  ) async throws {
    let runState = JetstreamRunState(cursor: options.cursor, policy: retryPolicy)
    var hasConnected = false

    while !Task.isCancelled {
      let lastCursor = await runState.cursor
      let cursor =
        hasConnected
        ? lastCursor.map { max(0, $0 - retryPolicy.cursorRewind) }
        : options.cursor
      let url = try subscriptionURL(options: options, cursor: cursor)
      stateHandler(.connecting(cursor: cursor))
      do {
        try await connector.connect(
          url: url,
          maxMessageSize: options.maxMessageSizeBytes,
          onConnected: {
            stateHandler(.connected(cursor: cursor))
          },
          onMessage: { data in
            let event: TangledEvent
            do {
              event = try JSONDecoder().decode(TangledEvent.self, from: data)
            } catch {
              throw TangledError.decoding(error)
            }
            if await runState.process(event) {
              continuation.yield(event)
            }
          }
        )
        hasConnected = true
        try await reconnect(
          error: TangledError.transport("Jetstream connection closed"),
          cursor: await runState.cursor,
          runState: runState
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as TangledError {
        switch error {
        case .decoding, .invalidRequest:
          throw error
        default:
          hasConnected = true
          try await reconnect(
            error: error,
            cursor: await runState.cursor,
            runState: runState
          )
        }
      } catch {
        hasConnected = true
        try await reconnect(
          error: error,
          cursor: await runState.cursor,
          runState: runState
        )
      }
    }
    throw CancellationError()
  }

  private func reconnect(
    error: any Error,
    cursor: Int64?,
    runState: JetstreamRunState
  ) async throws {
    let attempt = await runState.nextReconnectAttempt()
    let exponent = min(attempt - 1, 20)
    let delay = min(
      retryPolicy.maximumDelay,
      retryPolicy.baseDelay * pow(2, Double(exponent))
    )
    stateHandler(
      .reconnecting(
        cursor: cursor,
        attempt: attempt,
        delay: delay,
        reason: String(describing: error)
      )
    )
    try await sleeper.sleep(for: delay)
  }

  private func validate(_ options: JetstreamOptions) throws {
    guard endpoint.scheme == "wss" || endpoint.scheme == "ws",
      endpoint.host != nil
    else {
      throw TangledError.invalidRequest("Jetstream endpoint must use ws or wss")
    }
    guard options.wantedCollections.count <= 100 else {
      throw TangledError.invalidRequest("wantedCollections must contain at most 100 values")
    }
    guard options.wantedDIDs.count <= 10_000 else {
      throw TangledError.invalidRequest("wantedDIDs must contain at most 10000 values")
    }
    guard options.wantedCollections.allSatisfy({ !$0.isEmpty }) else {
      throw TangledError.invalidRequest("wantedCollections must not contain empty values")
    }
    guard options.wantedDIDs.allSatisfy({ $0.hasPrefix("did:") }) else {
      throw TangledError.invalidRequest("wantedDIDs must contain DIDs")
    }
    if let cursor = options.cursor, cursor < 0 {
      throw TangledError.invalidRequest("cursor must not be negative")
    }
    guard options.maxMessageSizeBytes > 0 else {
      throw TangledError.invalidRequest("maxMessageSizeBytes must be positive")
    }
  }

  private func subscriptionURL(options: JetstreamOptions, cursor: Int64?) throws -> URL {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw TangledError.invalidRequest("invalid Jetstream endpoint")
    }
    var queryItems = components.queryItems ?? []
    queryItems += options.wantedCollections.map {
      URLQueryItem(name: "wantedCollections", value: $0)
    }
    queryItems += options.wantedDIDs.map {
      URLQueryItem(name: "wantedDids", value: $0)
    }
    queryItems.append(
      URLQueryItem(name: "maxMessageSizeBytes", value: String(options.maxMessageSizeBytes))
    )
    if let cursor {
      queryItems.append(URLQueryItem(name: "cursor", value: String(cursor)))
    }
    components.queryItems = queryItems
    guard let url = components.url else {
      throw TangledError.invalidRequest("invalid Jetstream subscription URL")
    }
    return url
  }
}

private actor JetstreamRunState {
  private(set) var cursor: Int64?
  private var reconnectAttempt = 0
  private var recent: RecentJetstreamEvents

  init(cursor: Int64?, policy: JetstreamRetryPolicy) {
    self.cursor = cursor
    self.recent = RecentJetstreamEvents(policy: policy)
  }

  func process(_ event: TangledEvent) -> Bool {
    cursor = max(cursor ?? event.timeUS, event.timeUS)
    reconnectAttempt = 0
    return recent.insert(event)
  }

  func nextReconnectAttempt() -> Int {
    reconnectAttempt += 1
    return reconnectAttempt
  }
}

private struct RecentJetstreamEvents {
  private let policy: JetstreamRetryPolicy
  private var events = Set<TangledEvent>()
  private var order: [TangledEvent] = []

  init(policy: JetstreamRetryPolicy) {
    self.policy = policy
  }

  mutating func insert(_ event: TangledEvent) -> Bool {
    let threshold = event.timeUS - policy.deduplicationWindow
    while let first = order.first,
      first.timeUS < threshold || order.count >= policy.maximumRememberedEvents
    {
      order.removeFirst()
      events.remove(first)
    }
    guard events.insert(event).inserted else { return false }
    order.append(event)
    return true
  }
}
