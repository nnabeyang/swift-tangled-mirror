import Foundation
import OAuth4Swift
import SwiftAtproto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct TokenRevoker: Sendable {
  private let session: StoredSession
  private let clientId: String
  private let resolver: any ATPResolver
  private let urlSession: URLSession

  public init(
    session: StoredSession,
    clientId: String = OAuth.ClientInfo.tangledCLI.clientId,
    resolver: any ATPResolver = URLSessionATPResolver(),
    urlSession: URLSession = .shared
  ) {
    self.session = session
    self.clientId = clientId
    self.resolver = resolver
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
      return nil
    }
    guard let pdsService = doc.service?.first(where: { $0.id.hasSuffix("#atproto_pds") }),
      let pdsURL = URL(string: pdsService.serviceEndpoint)
    else {
      return nil
    }

    if let authServerURL = try await authServerURL(fromResource: pdsURL) {
      return try await revocationEndpoint(fromAuthServer: authServerURL)
    }
    return try await revocationEndpoint(fromAuthServer: pdsURL)
  }

  private func authServerURL(fromResource pdsURL: URL) async throws -> URL? {
    let url = pdsURL.appendingPathComponent(".well-known/oauth-protected-resource")
    guard let data = try await fetchMetadataJSON(url: url) else { return nil }
    struct Shape: Decodable {
      let authorization_servers: [String]?
    }
    let shape = try JSONDecoder().decode(Shape.self, from: data)
    guard let first = shape.authorization_servers?.first else { return nil }
    return URL(string: first)
  }

  private func revocationEndpoint(fromAuthServer authServerURL: URL) async throws -> URL? {
    let url = authServerURL.appendingPathComponent(".well-known/oauth-authorization-server")
    guard let data = try await fetchMetadataJSON(url: url) else { return nil }
    struct Shape: Decodable {
      let revocation_endpoint: URL?
    }
    let shape = try JSONDecoder().decode(Shape.self, from: data)
    return shape.revocation_endpoint
  }

  private func fetchMetadataJSON(url: URL) async throws -> Data? {
    let (data, response) = try await urlSession.data(for: URLRequest(url: url))
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      return nil
    }
    return data
  }
}
