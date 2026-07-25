#if canImport(Network) || os(Linux)
  import Foundation
  import Testing

  @testable import SwiftTangled

  #if canImport(FoundationNetworking)
    import FoundationNetworking
  #endif

  @Test func loopbackServerReturnsCallbackURL() async throws {
    let server = try LoopbackCallbackServer()
    let bound = try await server.start()

    async let received = server.waitForCallback(timeout: .seconds(5))

    let callbackURL = URL(
      string:
        "http://127.0.0.1:\(bound.port)/callback?code=abc&state=xyz&iss=https%3A%2F%2Fbsky.social"
    )!
    _ = try? await URLSession.shared.data(for: URLRequest(url: callbackURL))

    let url = try await received
    await server.stop()

    #expect(url.host == "127.0.0.1")
    #expect(url.port == Int(bound.port))
    #expect(url.path == "/callback")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(map["code"] == "abc")
    #expect(map["state"] == "xyz")
    #expect(map["iss"] == "https://bsky.social")
  }

  @Test func loopbackServerTimesOut() async throws {
    let server = try LoopbackCallbackServer()
    _ = try await server.start()

    await #expect(throws: TangledError.self) {
      _ = try await server.waitForCallback(timeout: .milliseconds(50))
    }
    await server.stop()
  }

  @Test func loopbackServerPreservesAccessDeniedURL() async throws {
    let server = try LoopbackCallbackServer()
    let bound = try await server.start()

    async let received = server.waitForCallback(timeout: .seconds(5))
    let callbackURL = URL(
      string: "http://127.0.0.1:\(bound.port)/callback?error=access_denied&state=xyz")!
    _ = try? await URLSession.shared.data(for: URLRequest(url: callbackURL))

    let url = try await received
    await server.stop()

    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(map["error"] == "access_denied")
    #expect(map["state"] == "xyz")
  }

  @Test func loopbackServerFailsWhenPortAlreadyInUse() async throws {
    let first = try LoopbackCallbackServer()
    let bound = try await first.start()
    defer { Task { await first.stop() } }

    await #expect(throws: TangledError.self) {
      let second = try LoopbackCallbackServer(port: bound.port)
      _ = try await second.start()
    }
  }

  @Test func loopbackServerBuffersCallbackUntilConsumerWaits() async throws {
    let server = try LoopbackCallbackServer()
    let bound = try await server.start()
    defer { Task { await server.stop() } }

    let callbackURL = URL(
      string: "http://127.0.0.1:\(bound.port)/callback?code=early&state=buffered")!
    _ = try await URLSession.shared.data(for: URLRequest(url: callbackURL))

    let url = try await server.waitForCallback(timeout: .seconds(5))
    #expect(url.query?.contains("code=early") == true)
    #expect(url.query?.contains("state=buffered") == true)
  }

  @Test func loopbackServerIgnoresUnrelatedRequest() async throws {
    let server = try LoopbackCallbackServer()
    let bound = try await server.start()
    defer { Task { await server.stop() } }
    async let received = server.waitForCallback(timeout: .seconds(5))

    let healthCheckURL = URL(string: "http://127.0.0.1:\(bound.port)/")!
    let (_, healthCheckResponse) = try await URLSession.shared.data(
      for: URLRequest(url: healthCheckURL))
    #expect((healthCheckResponse as? HTTPURLResponse)?.statusCode == 404)

    let callbackURL = URL(
      string:
        "http://127.0.0.1:\(bound.port)/callback?code=abc&state=xyz&iss=https%3A%2F%2Fbsky.social"
    )!
    _ = try await URLSession.shared.data(for: URLRequest(url: callbackURL))

    let url = try await received
    #expect(url == callbackURL)
  }

  @Test func loopbackServerIgnoresInvalidHTTPMethod() async throws {
    let server = try LoopbackCallbackServer()
    let bound = try await server.start()
    defer { Task { await server.stop() } }
    async let received = server.waitForCallback(timeout: .seconds(5))

    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:\(bound.port)/callback")!)
    request.httpMethod = "POST"
    let (_, invalidMethodResponse) = try await URLSession.shared.data(for: request)
    #expect((invalidMethodResponse as? HTTPURLResponse)?.statusCode == 405)

    let callbackURL = URL(
      string:
        "http://127.0.0.1:\(bound.port)/callback?code=abc&iss=https%3A%2F%2Fbsky.social"
    )!
    _ = try await URLSession.shared.data(for: URLRequest(url: callbackURL))

    let url = try await received
    #expect(url == callbackURL)
  }

  @Test func stoppingLoopbackServerCancelsPendingWait() async throws {
    let server = try LoopbackCallbackServer()
    _ = try await server.start()
    let callback = Task {
      try await server.waitForCallback(timeout: .seconds(5))
    }
    await Task.yield()

    await server.stop()

    do {
      _ = try await callback.value
      Issue.record("Expected cancellation")
    } catch TangledError.oauthCancelled(let reason) {
      #expect(reason == "server stopped")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func loopbackAuthenticatorOpensBrowserAndReturnsCallback() async throws {
    let server = try LoopbackCallbackServer()
    let bound = try await server.start()
    defer { Task { await server.stop() } }
    let callbackURL = URL(
      string: "http://127.0.0.1:\(bound.port)/callback?code=abc&state=expected")!
    let browser = CallbackBrowserLauncher(callbackURL: callbackURL)
    let authenticator = LoopbackUserAuthenticator.make(
      server: server,
      browser: browser,
      timeout: .seconds(5)
    )
    let authorizationURL = URL(string: "https://auth.example/authorize")!

    let returnedURL = try await authenticator(authorizationURL, "http")

    #expect(browser.openedURL == authorizationURL)
    #expect(returnedURL == callbackURL)
  }

  private final class CallbackBrowserLauncher: BrowserLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private let callbackURL: URL
    private var recordedURL: URL?

    init(callbackURL: URL) {
      self.callbackURL = callbackURL
    }

    var openedURL: URL? {
      lock.withLock { recordedURL }
    }

    func open(_ url: URL) async throws {
      lock.withLock {
        recordedURL = url
      }
      _ = try await URLSession.shared.data(for: URLRequest(url: callbackURL))
    }
  }
#endif
