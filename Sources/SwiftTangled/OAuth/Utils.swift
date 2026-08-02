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
  package let revocationEndpoint: URL?
}

package enum AtprotoOAuthDiscoveryError: Error, Equatable {
  case missingDIDDocument
  case missingProtectedResourceMetadata
  case invalidAuthorizationServerCount(Int)
  case invalidAuthorizationServerOrigin
  case missingAuthorizationServerMetadata
  case invalidAuthorizationServerMetadata
}

extension AtprotoOAuthDiscoveryError: LocalizedError {
  package var errorDescription: String? {
    switch self {
    case .missingDIDDocument:
      "OAuth discovery could not resolve the account DID document."
    case .missingProtectedResourceMetadata:
      "The PDS did not publish OAuth protected resource metadata."
    case .invalidAuthorizationServerCount(let count):
      "OAuth protected resource metadata must contain exactly one authorization server, got \(count)."
    case .invalidAuthorizationServerOrigin:
      "The OAuth authorization server must be a simple HTTPS origin."
    case .missingAuthorizationServerMetadata:
      "The OAuth authorization server did not publish metadata."
    case .invalidAuthorizationServerMetadata:
      "The OAuth authorization server metadata could not be inspected."
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
      let pdsResourceMetadata = try await authFetcher.resourceDiscoveryRequest(
        url: pdsServiceEndpoint
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
      origin: authorizationServerURL,
      revocationEndpoint: try revocationEndpoint(from: authMetadata)
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

  // OAuth4Swift 0.6.0-soyokaze.1 decodes this field as URL but does not expose it.
  // Keep the compatibility access at the shared discovery boundary until it becomes public.
  private static func revocationEndpoint(from metadata: AuthServerMetadata) throws -> URL? {
    let data = try JSONEncoder().encode(metadata)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AtprotoOAuthDiscoveryError.invalidAuthorizationServerMetadata
    }
    guard let rawValue = object["revocation_endpoint"] else { return nil }
    guard let string = rawValue as? String, let url = URL(string: string) else {
      throw AtprotoOAuthDiscoveryError.invalidAuthorizationServerMetadata
    }
    return url
  }
}
