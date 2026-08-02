import Foundation
import GermConvenience
import HTTPTypes
import OAuth4Swift
import Testing

@testable import SwiftTangled

@Suite struct AtprotoOAuthUtilsTests {
  @Test func discoversASeparateAuthorizationServerAndRevocationEndpoint() async throws {
    let fetcher = MetadataFetcher(stubs: [
      protectedResourceURL: .ok(
        protectedResourceMetadata(authorizationServers: ["https://auth.example"])
      ),
      authorizationServerURL: .ok(authorizationServerMetadata()),
    ])

    let server = try await AtprotoOAuthUtils.authorizationServer(
      pdsServiceEndpoint: URL(string: "https://pds.example")!,
      authFetcher: fetcher
    )

    #expect(server.origin == URL(string: "https://auth.example"))
    #expect(server.metadata.issuer == "https://auth.example")
    #expect(server.revocationEndpoint == URL(string: "https://auth.example/oauth/revoke"))
    #expect(await fetcher.requestedURLs() == [protectedResourceURL, authorizationServerURL])
  }

  @Test func requiresExactlyOneAuthorizationServer() async throws {
    for servers in [[], ["https://one.example", "https://two.example"]] {
      let fetcher = MetadataFetcher(stubs: [
        protectedResourceURL: .ok(protectedResourceMetadata(authorizationServers: servers))
      ])

      do {
        _ = try await AtprotoOAuthUtils.authorizationServer(
          pdsServiceEndpoint: URL(string: "https://pds.example")!,
          authFetcher: fetcher
        )
        Issue.record("expected authorization server count failure")
      } catch AtprotoOAuthDiscoveryError.invalidAuthorizationServerCount(let count) {
        #expect(count == servers.count)
      } catch {
        Issue.record("unexpected error: \(error)")
      }
    }
  }

  @Test func rejectsAuthorizationServersThatAreNotSimpleHTTPSOrigins() async throws {
    for origin in [
      "http://auth.example",
      "https://user:password@auth.example",
      "https://auth.example/oauth",
      "https://auth.example?tenant=one",
      "https://auth.example#fragment",
      "https://auth.example:443",
      "not a URL",
    ] {
      let fetcher = MetadataFetcher(stubs: [
        protectedResourceURL: .ok(protectedResourceMetadata(authorizationServers: [origin]))
      ])

      await #expect(throws: AtprotoOAuthDiscoveryError.invalidAuthorizationServerOrigin) {
        _ = try await AtprotoOAuthUtils.authorizationServer(
          pdsServiceEndpoint: URL(string: "https://pds.example")!,
          authFetcher: fetcher
        )
      }
      #expect(await fetcher.requestedURLs() == [protectedResourceURL])
    }
  }

  @Test func reportsMissingResourceAndAuthorizationServerMetadata() async throws {
    let missingResource = MetadataFetcher(stubs: [:])
    await #expect(throws: AtprotoOAuthDiscoveryError.missingProtectedResourceMetadata) {
      _ = try await AtprotoOAuthUtils.authorizationServer(
        pdsServiceEndpoint: URL(string: "https://pds.example")!,
        authFetcher: missingResource
      )
    }

    let missingAuthorizationServer = MetadataFetcher(stubs: [
      protectedResourceURL: .ok(
        protectedResourceMetadata(authorizationServers: ["https://auth.example"])
      )
    ])
    await #expect(throws: AtprotoOAuthDiscoveryError.missingAuthorizationServerMetadata) {
      _ = try await AtprotoOAuthUtils.authorizationServer(
        pdsServiceEndpoint: URL(string: "https://pds.example")!,
        authFetcher: missingAuthorizationServer
      )
    }
  }

  @Test func propagatesMetadataTransportAndDecodingFailures() async throws {
    let transportFailure = MetadataFetcher(
      stubs: [protectedResourceURL: .failure(MetadataTestError.transport)]
    )
    await #expect(throws: MetadataTestError.transport) {
      _ = try await AtprotoOAuthUtils.authorizationServer(
        pdsServiceEndpoint: URL(string: "https://pds.example")!,
        authFetcher: transportFailure
      )
    }

    let invalidJSON = MetadataFetcher(stubs: [protectedResourceURL: .ok(Data("{".utf8))])
    await #expect(throws: (any Error).self) {
      _ = try await AtprotoOAuthUtils.authorizationServer(
        pdsServiceEndpoint: URL(string: "https://pds.example")!,
        authFetcher: invalidJSON
      )
    }
  }
}

private let protectedResourceURL =
  "https://pds.example/.well-known/oauth-protected-resource"
private let authorizationServerURL =
  "https://auth.example/.well-known/oauth-authorization-server"

func protectedResourceMetadata(authorizationServers: [String]) -> Data {
  let object: [String: Any] = [
    "resource": "https://pds.example",
    "authorization_servers": authorizationServers,
  ]
  return try! JSONSerialization.data(withJSONObject: object)
}

func authorizationServerMetadata(revocationEndpoint: Bool = true) -> Data {
  var object: [String: Any] = [
    "issuer": "https://auth.example",
    "authorization_endpoint": "https://auth.example/oauth/authorize",
    "token_endpoint": "https://auth.example/oauth/token",
    "dpop_signing_alg_values_supported": ["ES256"],
  ]
  if revocationEndpoint {
    object["revocation_endpoint"] = "https://auth.example/oauth/revoke"
  }
  return try! JSONSerialization.data(withJSONObject: object)
}

private enum MetadataTestError: Error {
  case transport
}

private actor MetadataFetcher: HTTPFetcher {
  enum Stub: Sendable {
    case response(Data, HTTPResponse.Status)
    case failure(MetadataTestError)

    static func ok(_ data: Data) -> Stub { .response(data, .ok) }
  }

  private let stubs: [String: Stub]
  private var requests: [String] = []

  init(stubs: [String: Stub]) {
    self.stubs = stubs
  }

  func data(for request: BundledHTTPRequest) async throws -> HTTPDataResponse {
    let url = request.request.url!.absoluteString
    requests.append(url)
    switch stubs[url] ?? .response(Data(), .notFound) {
    case .response(let data, let status):
      return HTTPDataResponse(data: data, response: HTTPResponse(status: status))
    case .failure(let error):
      throw error
    }
  }

  func requestedURLs() -> [String] { requests }
}
