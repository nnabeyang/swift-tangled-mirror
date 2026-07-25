import Testing

@testable import SwiftTangled

@Test func atprotoOAuthPublicTypesAreVisible() {
  _ = AtprotoOAuthClient.self
  _ = AtprotoOAuthAgent.self
  _ = OAuthClientError.self
  _ = OAuthSessionError.self
  _ = ProxyDID.self
  _ = FallbackResolver.self
}
