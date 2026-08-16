import Foundation
import GermConvenience
import OAuth4Swift
import SwiftAtproto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct TokenRevoker: Sendable {
  private let session: StoredSession
  private let clientId: String
  private let resolver: any ATPResolver
  private let authFetcher: any HTTPFetcher
  private let urlSession: URLSession

  public init(
    session: StoredSession,
    clientId: String? = nil,
    resolver: any ATPResolver = URLSessionATPResolver(),
    authFetcher: any HTTPFetcher = URLSession.manualRedirect(),
    urlSession: URLSession = .shared
  ) {
    self.session = session
    self.clientId = clientId ?? session.resolvedClientID
    self.resolver = resolver
    self.authFetcher = authFetcher
    self.urlSession = urlSession
  }

  public func revoke() async throws {
    guard let refreshToken = session.archive.tokenState.refreshToken else {
      return
    }
    guard let revocationEndpoint = try await discoverRevocationEndpoint() else {
      return
    }

    var request = URLRequest(url: revocationEndpoint)
    request.httpMethod = "POST"
    request.setValue(
      "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var components = URLComponents()
    components.queryItems = [
      URLQueryItem(name: "token", value: refreshToken.value),
      URLQueryItem(name: "token_type_hint", value: "refresh_token"),
      URLQueryItem(name: "client_id", value: clientId),
    ]
    request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

    let (_, response) = try await urlSession.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw TangledError.serverStatus(-1, "non-HTTP revocation response")
    }
    guard (200 ..< 300).contains(http.statusCode) else {
      throw TangledError.serverStatus(http.statusCode, "revocation failed")
    }
  }

  private func discoverRevocationEndpoint() async throws -> URL? {
    let did = try DID(string: session.did)
    guard let doc = try await resolver.resolve(did: did) else {
      throw AtprotoOAuthDiscoveryError.missingDIDDocument
    }
    return try await AtprotoOAuthUtils.authorizationServer(
      pdsServiceEndpoint: try doc.pdsUrl,
      authFetcher: authFetcher
    ).revocationEndpoint
  }
}
