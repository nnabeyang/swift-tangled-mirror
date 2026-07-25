#if os(Linux)
  import Foundation
  import Glibc

  public actor LoopbackCallbackServer {
    public struct Bound: Sendable {
      public let port: UInt16
    }

    private static let maximumRequestBytes = 8 * 1024

    private var listenerDescriptor: Int32
    private let port: UInt16
    private let queue = DispatchQueue(
      label: "swift-tangled.loopback-callback.posix",
      attributes: .concurrent
    )
    private var pendingCallback: CheckedContinuation<URL, any Error>?
    private var bufferedCallback: URL?
    private var handledCallback = false
    private var started = false
    private var stopped = false

    public init() throws {
      let listener = try Self.makeListener(port: 0)
      listenerDescriptor = listener.descriptor
      port = listener.port
    }

    public init(port: UInt16) throws {
      guard port > 0 else {
        throw TangledError.portBindFailure("invalid port \(port)")
      }
      let listener = try Self.makeListener(port: port)
      listenerDescriptor = listener.descriptor
      self.port = listener.port
    }

    deinit {
      if listenerDescriptor >= 0 {
        _ = Glibc.close(listenerDescriptor)
      }
    }

    public func start() async throws -> Bound {
      guard !stopped else {
        throw TangledError.portBindFailure("listener is stopped")
      }
      if !started {
        started = true
        let descriptor = listenerDescriptor
        queue.async { [weak self] in
          Self.acceptConnections(on: descriptor, server: self)
        }
      }
      return Bound(port: port)
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

    public func stop() {
      guard !stopped else { return }
      stopped = true
      let descriptor = listenerDescriptor
      listenerDescriptor = -1
      _ = Glibc.shutdown(descriptor, Int32(SHUT_RDWR))
      _ = Glibc.close(descriptor)
      if let continuation = pendingCallback {
        pendingCallback = nil
        continuation.resume(throwing: TangledError.oauthCancelled("server stopped"))
      }
    }

    private func fireTimeout() {
      guard let continuation = pendingCallback else { return }
      pendingCallback = nil
      continuation.resume(throwing: TangledError.oauthTimeout)
    }

    private func processRequest(_ result: Result<String, any Error>, descriptor: Int32) {
      guard !stopped else {
        _ = Glibc.close(descriptor)
        return
      }
      guard !handledCallback else {
        Self.respondClosed(descriptor: descriptor, body: "already handled")
        return
      }

      let line: String
      do {
        line = try result.get()
      } catch {
        Self.respondClosed(
          descriptor: descriptor,
          status: "400 Bad Request",
          body: "invalid HTTP request"
        )
        return
      }

      let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard parts.count >= 2 else {
        Self.respondClosed(
          descriptor: descriptor,
          status: "400 Bad Request",
          body: "invalid request"
        )
        return
      }
      guard parts[0] == "GET" else {
        Self.respondClosed(
          descriptor: descriptor,
          status: "405 Method Not Allowed",
          body: "expected GET"
        )
        return
      }
      guard let url = URL(string: "http://127.0.0.1:\(port)\(parts[1])") else {
        Self.respondClosed(
          descriptor: descriptor,
          status: "400 Bad Request",
          body: "bad URL"
        )
        return
      }
      guard url.path == "/callback" else {
        Self.respondClosed(
          descriptor: descriptor,
          status: "404 Not Found",
          body: "not found"
        )
        return
      }

      handledCallback = true
      Self.respondClosed(
        descriptor: descriptor,
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

    private nonisolated static func makeListener(
      port: UInt16
    ) throws -> (descriptor: Int32, port: UInt16) {
      let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
      guard descriptor >= 0 else {
        throw portFailure("could not create socket")
      }
      var shouldClose = true
      defer {
        if shouldClose {
          _ = Glibc.close(descriptor)
        }
      }
      guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
        throw portFailure("could not secure socket")
      }

      var reuseAddress: Int32 = 1
      guard
        setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_REUSEADDR,
          &reuseAddress,
          socklen_t(MemoryLayout.size(ofValue: reuseAddress))
        ) == 0
      else {
        throw portFailure("could not configure socket")
      }

      var address = sockaddr_in()
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = in_port_t(port.bigEndian)
      address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
      let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Glibc.bind(
            descriptor,
            $0,
            socklen_t(MemoryLayout<sockaddr_in>.size)
          )
        }
      }
      guard bindResult == 0 else {
        throw portFailure("could not bind socket")
      }
      guard Glibc.listen(descriptor, 4) == 0 else {
        throw portFailure("could not listen on socket")
      }

      var boundAddress = sockaddr_in()
      var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
      let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          getsockname(descriptor, $0, &boundLength)
        }
      }
      guard nameResult == 0 else {
        throw portFailure("could not determine bound port")
      }

      shouldClose = false
      return (descriptor, UInt16(bigEndian: boundAddress.sin_port))
    }

    private nonisolated static func acceptConnections(
      on listenerDescriptor: Int32,
      server: LoopbackCallbackServer?
    ) {
      while true {
        let descriptor = Glibc.accept(listenerDescriptor, nil, nil)
        guard descriptor >= 0 else {
          if errno == EINTR { continue }
          return
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        guard let server else {
          _ = Glibc.close(descriptor)
          return
        }
        server.queue.async {
          let result = readRequestLine(from: descriptor)
          Task {
            await server.processRequest(result, descriptor: descriptor)
          }
        }
      }
    }

    private nonisolated static func readRequestLine(
      from descriptor: Int32
    ) -> Result<String, any Error> {
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 1024)
      var foundNewline = false
      while data.count < maximumRequestBytes {
        let received = Glibc.recv(descriptor, &buffer, buffer.count, 0)
        if received > 0 {
          data.append(buffer, count: received)
          if data.contains(0x0A) {
            foundNewline = true
            break
          }
          continue
        }
        if received < 0, errno == EINTR { continue }
        break
      }

      guard foundNewline, data.count <= maximumRequestBytes,
        let text = String(data: data, encoding: .utf8),
        let line = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first
      else {
        return .failure(TangledError.oauthCancelled("invalid HTTP request"))
      }
      return .success(String(line))
    }

    private nonisolated static func respondClosed(
      descriptor: Int32,
      status: String = "200 OK",
      body: String
    ) {
      let response =
        "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
      let bytes = Array(response.utf8)
      bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let sent = Glibc.send(
            descriptor,
            buffer.baseAddress!.advanced(by: offset),
            buffer.count - offset,
            Int32(MSG_NOSIGNAL)
          )
          if sent > 0 {
            offset += sent
          } else if sent < 0, errno == EINTR {
            continue
          } else {
            break
          }
        }
      }
      _ = Glibc.shutdown(descriptor, Int32(SHUT_RDWR))
      _ = Glibc.close(descriptor)
    }

    private nonisolated static func portFailure(_ context: String) -> TangledError {
      TangledError.portBindFailure(
        "\(context): \(String(cString: strerror(errno)))"
      )
    }
  }
#endif
