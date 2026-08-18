import Foundation
import GermConvenience
import OAuth4Swift

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct TokenRevoker: Sendable {
  private let session: StoredSession
  private let clientId: String
  private let resolver: any ATPResolver
  private let authFetcher: any HTTPFetcher

  public init(
    session: StoredSession,
    clientId: String? = nil,
    resolver: any ATPResolver = URLSessionATPResolver(),
    authFetcher: any HTTPFetcher = URLSession.manualRedirect()
  ) {
    self.session = session
    self.clientId = clientId ?? session.resolvedClientID
    self.resolver = resolver
    self.authFetcher = authFetcher
  }

  // RFC 7009 2.1: revoking the refresh token also invalidates the grant's
  // access tokens.
  public func revoke() async throws {
    guard let refreshToken = session.archive.tokenState.refreshToken else {
      return
    }
    let (agent, _) = try AtprotoOAuthAgent.restore(
      archive: .init(did: session.did, session: session.archive),
      clientId: clientId,
      authFetcher: authFetcher,
      atprotoResolver: resolver,
      delegate: nil
    )
    try await agent.revocationRequest(
      authServerMetadata: try await agent.authServerMetadata,
      token: refreshToken
    )
  }
}
