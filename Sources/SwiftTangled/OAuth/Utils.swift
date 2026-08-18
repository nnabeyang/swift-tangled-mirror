//
//  AtprotoOAuthUtils.swift
//  AtprotoOAuth
//
//  Created by Anna Mistele on 4/9/26.
//

import Foundation
import GermConvenience
import OAuth4Swift

package struct AtprotoAuthorizationServer: Sendable {
  package let metadata: AuthServerMetadata
  package let origin: URL
}

package enum AtprotoOAuthDiscoveryError: Error, Equatable {
  case missingProtectedResourceMetadata
  case invalidAuthorizationServerCount(Int)
  case invalidAuthorizationServerOrigin
  case missingAuthorizationServerMetadata
}

extension AtprotoOAuthDiscoveryError: LocalizedError {
  package var errorDescription: String? {
    switch self {
    case .missingProtectedResourceMetadata:
      "The PDS did not publish OAuth protected resource metadata."
    case .invalidAuthorizationServerCount(let count):
      "OAuth protected resource metadata must contain exactly one authorization server, got \(count)."
    case .invalidAuthorizationServerOrigin:
      "The OAuth authorization server must be a simple HTTPS origin."
    case .missingAuthorizationServerMetadata:
      "The OAuth authorization server did not publish metadata."
    }
  }
}

public struct AtprotoOAuthUtils {
  public static func getAuthorizationServerURL(
    pdsServiceEndpoint: URL,
    authFetcher: HTTPFetcher
  ) async throws -> (AuthServerMetadata, URL) {
    let server = try await authorizationServer(
      pdsServiceEndpoint: pdsServiceEndpoint,
      authFetcher: authFetcher
    )
    return (server.metadata, server.origin)
  }

  package static func authorizationServer(
    pdsServiceEndpoint: URL,
    authFetcher: HTTPFetcher
  ) async throws -> AtprotoAuthorizationServer {
    guard
      let pdsResourceMetadata = try await protectedResourceMetadata(
        pdsServiceEndpoint: pdsServiceEndpoint,
        authFetcher: authFetcher
      )
    else {
      throw AtprotoOAuthDiscoveryError.missingProtectedResourceMetadata
    }

    if let supportedAlgs = pdsResourceMetadata.dpopSigningAlgValuesSupported {
      guard supportedAlgs.contains("ES256") else {
        throw OAuthSessionError.unsupportedDpopSigningAlgorithm
      }
    }

    let authServers = pdsResourceMetadata.authorizationServers ?? []
    guard authServers.count == 1, let authorizationServerString = authServers.first else {
      throw AtprotoOAuthDiscoveryError.invalidAuthorizationServerCount(authServers.count)
    }
    guard let authorizationServerURL = authorizationServerOrigin(authorizationServerString) else {
      throw AtprotoOAuthDiscoveryError.invalidAuthorizationServerOrigin
    }

    guard
      let authMetadata = try await authFetcher.authServerDiscovery(
        endpoint: authorizationServerURL
      )
    else {
      throw AtprotoOAuthDiscoveryError.missingAuthorizationServerMetadata
    }

    if let supportedAlgs = authMetadata.dpopSigningAlgValuesSupported {
      guard supportedAlgs.contains("ES256") else {
        throw OAuthSessionError.unsupportedDpopSigningAlgorithm
      }
    }

    return AtprotoAuthorizationServer(
      metadata: authMetadata,
      origin: authorizationServerURL
    )
  }

  private static func authorizationServerOrigin(_ rawValue: String) -> URL? {
    guard let url = URL(string: rawValue),
      url.scheme?.lowercased() == "https",
      let host = url.host,
      !host.isEmpty,
      url.user == nil,
      url.password == nil,
      url.path.isEmpty || url.path == "/",
      url.query == nil,
      url.fragment == nil,
      url.port != 443
    else {
      return nil
    }
    return url
  }

  // RFC 9728 3.1 prepends the well-known segment to the resource path;
  // OAuth4Swift's resourceDiscoveryRequest appends it.
  private static func protectedResourceMetadata(
    pdsServiceEndpoint: URL,
    authFetcher: HTTPFetcher
  ) async throws -> ProtectedResourceMetadata? {
    let url = try protectedResourceMetadataURL(for: pdsServiceEndpoint)
    guard url.scheme == "https" else {
      throw OAuth.Errors.insecureScheme
    }
    let response = try await authFetcher.data(for: try BundledHTTPRequest(url: url))
    guard response.response.status != .notFound else {
      return nil
    }
    return try response.expectSuccess().decode()
  }

  private static func protectedResourceMetadataURL(for resource: URL) throws -> URL {
    var components = try URLComponents(
      url: resource,
      resolvingAgainstBaseURL: false
    ).tryUnwrap(OAuth.Errors.invalidRequest)

    let resourcePath = components.percentEncodedPath
    let pathSuffix: String
    switch resourcePath {
    case "", "/":
      pathSuffix = ""
    case let path where path.hasPrefix("/"):
      pathSuffix = path
    default:
      pathSuffix = "/\(resourcePath)"
    }

    components.percentEncodedPath =
      "/.well-known/oauth-protected-resource" + pathSuffix

    return try components.url.tryUnwrap(OAuth.Errors.invalidRequest)
  }
}
