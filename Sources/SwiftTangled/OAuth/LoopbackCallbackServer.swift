#if canImport(Network)
  import Foundation
  import Network

  public actor LoopbackCallbackServer {
    public struct Bound: Sendable {
      public let port: UInt16
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "swift-tangled.loopback-callback")
    private var boundPort: UInt16?
    private var pendingCallback: CheckedContinuation<URL, any Error>?
    private var bufferedCallback: URL?
    private var startContinuation: CheckedContinuation<UInt16, any Error>?
    private var handledCallback = false
    private var stopped = false

    public init() throws {
      let params = NWParameters.tcp
      params.acceptLocalOnly = true
      do {
        self.listener = try NWListener(using: params, on: .any)
      } catch {
        throw TangledError.portBindFailure(String(describing: error))
      }
    }

    public init(port: UInt16) throws {
      guard let port = NWEndpoint.Port(rawValue: port) else {
        throw TangledError.portBindFailure("invalid port \(port)")
      }
      let params = NWParameters.tcp
      params.acceptLocalOnly = true
      do {
        self.listener = try NWListener(using: params, on: port)
      } catch {
        throw TangledError.portBindFailure(String(describing: error))
      }
    }

    public func start() async throws -> Bound {
      let port = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<UInt16, any Error>) in
        self.startContinuation = continuation
        listener.stateUpdateHandler = { [weak self] state in
          guard let self else { return }
          Task { await self.handleState(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
          guard let self else { return }
          Task { await self.accept(connection) }
        }
        listener.start(queue: queue)
      }
      return Bound(port: port)
    }

    private func handleState(_ state: NWListener.State) {
      guard let continuation = startContinuation else { return }
      switch state {
      case .ready:
        if let port = listener.port?.rawValue {
          boundPort = port
          startContinuation = nil
          continuation.resume(returning: port)
        } else {
          startContinuation = nil
          continuation.resume(
            throwing: TangledError.portBindFailure("listener ready but port unavailable"))
        }
      case .failed(let error):
        startContinuation = nil
        continuation.resume(throwing: TangledError.portBindFailure(String(describing: error)))
      default:
        break
      }
    }

    public func waitForCallback(timeout: Duration = .seconds(300)) async throws -> URL {
      let timeoutTask = Task {
        try? await Task.sleep(for: timeout)
        self.fireTimeout()
      }
      defer { timeoutTask.cancel() }
      return try await withCheckedThrowingContinuation { continuation in
        if stopped {
          continuation.resume(throwing: TangledError.oauthCancelled("server stopped"))
        } else if let url = bufferedCallback {
          bufferedCallback = nil
          continuation.resume(returning: url)
        } else {
          pendingCallback = continuation
        }
      }
    }

    private func fireTimeout() {
      guard let continuation = pendingCallback else { return }
      pendingCallback = nil
      continuation.resume(throwing: TangledError.oauthTimeout)
    }

    public func stop() {
      guard !stopped else { return }
      stopped = true
      listener.cancel()
      if let continuation = pendingCallback {
        pendingCallback = nil
        continuation.resume(throwing: TangledError.oauthCancelled("server stopped"))
      }
    }

    private func accept(_ connection: NWConnection) {
      connection.start(queue: queue)
      receive(on: connection)
    }

    private nonisolated func receive(on connection: NWConnection) {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) {
        [weak self] data, _, isComplete, error in
        guard let self else {
          connection.cancel()
          return
        }
        if let data, let line = Self.firstRequestLine(in: data) {
          Task { await self.processRequestLine(line, on: connection) }
          return
        }
        if isComplete || error != nil {
          connection.cancel()
        }
      }
    }

    private func processRequestLine(_ line: String, on connection: NWConnection) {
      guard !handledCallback else {
        Self.respondClosed(on: connection, body: "already handled")
        return
      }

      let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard parts.count >= 2 else {
        Self.respondClosed(on: connection, status: "400 Bad Request", body: "invalid request")
        return
      }
      guard parts[0] == "GET" else {
        Self.respondClosed(on: connection, status: "405 Method Not Allowed", body: "expected GET")
        return
      }
      guard let port = boundPort,
        let url = URL(string: "http://127.0.0.1:\(port)\(parts[1])")
      else {
        Self.respondClosed(on: connection, status: "400 Bad Request", body: "bad URL")
        return
      }
      guard url.path == "/callback" else {
        Self.respondClosed(on: connection, status: "404 Not Found", body: "not found")
        return
      }
      handledCallback = true
      Self.respondClosed(
        on: connection,
        body: "<html><body>Authorization complete. You can close this window.</body></html>"
      )
      deliverURL(url)
    }

    private func deliverURL(_ url: URL) {
      if let continuation = pendingCallback {
        pendingCallback = nil
        continuation.resume(returning: url)
      } else {
        bufferedCallback = url
      }
    }

    private static func firstRequestLine(in data: Data) -> String? {
      guard let text = String(data: data, encoding: .utf8) else { return nil }
      return text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init)
    }

    private static func respondClosed(
      on connection: NWConnection, status: String = "200 OK", body: String
    ) {
      let response =
        "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
      connection.send(
        content: Data(response.utf8),
        completion: .contentProcessed { _ in
          connection.cancel()
        })
    }
  }
#endif
