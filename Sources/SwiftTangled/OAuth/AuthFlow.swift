import Foundation
import GermConvenience
import OAuth4Swift
import SwiftAtproto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct AuthFlowResult: Sendable {
  public let did: String
  public let handle: String
}

public struct AuthFlow: Sendable {
  private let resolver: any ATPResolver
  private let browser: any BrowserLauncher
  private let sessionStore: (any SessionStore)?
  private let callbackTimeout: Duration
  private let callbackPort: UInt16?
  private let profile: AuthenticationProfile?

  public init(
    resolver: any ATPResolver = URLSessionATPResolver(),
    browser: any BrowserLauncher = .system,
    sessionStore: (any SessionStore)? = nil,
    callbackTimeout: Duration = .seconds(300),
    callbackPort: UInt16? = nil,
    profile: AuthenticationProfile? = nil
  ) {
    self.resolver = resolver
    self.browser = browser
    self.sessionStore = sessionStore
    self.callbackTimeout = callbackTimeout
    self.callbackPort = callbackPort
    self.profile = profile
  }

  public func login(handle rawHandle: String) async throws -> AuthFlowResult {
    let handle: Handle
    do {
      handle = try Handle(string: rawHandle)
    } catch {
      throw TangledError.handleNotResolved(rawHandle)
    }

    let server =
      if let callbackPort {
        try LoopbackCallbackServer(port: callbackPort)
      } else {
        try LoopbackCallbackServer()
      }
    let bound = try await server.start()
    defer {
      Task { await server.stop() }
    }

    let clientInfo = OAuth.ClientInfo.tangledCLI(boundPort: bound.port, profile: profile)
    let client = AtprotoOAuthClient(
      clientInfo: clientInfo,
      resolver: resolver,
      authFetcher: URLSession.manualRedirect(),
      userAuthenticator: LoopbackUserAuthenticator.make(
        server: server,
        browser: browser,
        timeout: callbackTimeout
      )
    )

    let (archive, did) = try await client.authorize(
      identity: .handle(handle)
    )
    if let store = sessionStore {
      let stored = StoredSession(
        did: did.rawValue,
        handle: handle.rawValue,
        profile: profile,
        archive: archive
      )
      try store.write(stored)
    }
    return AuthFlowResult(did: did.rawValue, handle: handle.rawValue)
  }
}
