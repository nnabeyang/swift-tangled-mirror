import Foundation
import GermConvenience
import HTTPTypes
import OAuth4Swift
import SwiftAtproto
import Testing

@testable import SwiftTangled

@Suite struct TokenRevokerTests {
  @Test func revokesRefreshTokenAtDiscoveredAuthorizationServer() async throws {
    let resolver = RevocationResolver(document: validDIDDocument())
    let fetcher = RevocationFetcher(includeRevocationEndpoint: true)

    try await makeRevoker(resolver: resolver, fetcher: fetcher).revoke()

    let request = try #require(await fetcher.revocationRequest())
    #expect(request.request.url?.absoluteString == "https://auth.example/oauth/revoke")
    #expect(request.request.method == .post)
    #expect(
      request.request.headerFields[.contentType] == HTTPContentType.formUrlEncoded.rawValue
    )
    #expect(request.request.headerFields[.init("DPoP")!] != nil)
    let fields = formFields(try #require(request.body))
    #expect(fields["token"] == "private-refresh-token")
    #expect(fields["token_type_hint"] == "refresh_token")
    #expect(fields["client_id"] == "https://client.example/metadata.json")
  }

  @Test func defaultsToStoredClientID() async throws {
    let resolver = RevocationResolver(document: validDIDDocument())
    let fetcher = RevocationFetcher(includeRevocationEndpoint: true)
    let session = try SessionStoreTestHelpers.makeStoredSession(
      storedClientID: "https://stored.example/metadata.json",
      includeDPoPKey: true,
      refreshToken: "private-refresh-token"
    )

    try await makeRevoker(
      session: session,
      clientId: nil,
      resolver: resolver,
      fetcher: fetcher
    ).revoke()

    let request = try #require(await fetcher.revocationRequest())
    let fields = formFields(try #require(request.body))
    #expect(fields["client_id"] == "https://stored.example/metadata.json")
  }

  @Test func missingRefreshTokenSkipsResolutionDiscoveryAndRequest() async throws {
    let resolver = RevocationResolver(document: validDIDDocument())
    let fetcher = RevocationFetcher(includeRevocationEndpoint: true)
    let session = try SessionStoreTestHelpers.makeStoredSession(
      includeDPoPKey: true,
      refreshToken: nil
    )

    try await makeRevoker(session: session, resolver: resolver, fetcher: fetcher).revoke()

    #expect(await resolver.resolveCount() == 0)
    #expect(await fetcher.requestedURLs().isEmpty)
  }

  @Test func missingRevocationEndpointIsANoOp() async throws {
    let resolver = RevocationResolver(document: validDIDDocument())
    let fetcher = RevocationFetcher(includeRevocationEndpoint: false)

    try await makeRevoker(resolver: resolver, fetcher: fetcher).revoke()

    #expect(await fetcher.requestedURLs() == [protectedResourceURL, authorizationServerURL])
    #expect(await fetcher.revocationRequest() == nil)
  }

  @Test func unresolvableDIDsAndInvalidPDSServicesFailBeforeDiscovery() async throws {
    for document in [
      nil,
      validDIDDocument(type: "NotAPersonalDataServer"),
      validDIDDocument(endpoint: "not a URL"),
    ] {
      let resolver = RevocationResolver(document: document)
      let fetcher = RevocationFetcher(includeRevocationEndpoint: true)

      await #expect(throws: (any Error).self) {
        try await makeRevoker(resolver: resolver, fetcher: fetcher).revoke()
      }
      #expect(await fetcher.requestedURLs().isEmpty)
    }
  }

  @Test func revocationFailureDoesNotExposeTheRefreshToken() async throws {
    let resolver = RevocationResolver(document: validDIDDocument())
    let fetcher = RevocationFetcher(
      includeRevocationEndpoint: true,
      revocationStatus: .serviceUnavailable
    )

    do {
      try await makeRevoker(resolver: resolver, fetcher: fetcher).revoke()
      Issue.record("expected revocation failure")
    } catch {
      #expect(!String(describing: error).contains("private-refresh-token"))
      #expect(!error.localizedDescription.contains("private-refresh-token"))
      guard let responseError = error as? HTTPResponseError else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(responseError.code == 503)
    }
  }

  private func makeRevoker(
    session: StoredSession? = nil,
    clientId: String? = "https://client.example/metadata.json",
    resolver: RevocationResolver,
    fetcher: RevocationFetcher
  ) throws -> TokenRevoker {
    TokenRevoker(
      session: try session
        ?? SessionStoreTestHelpers.makeStoredSession(
          includeDPoPKey: true,
          refreshToken: "private-refresh-token"
        ),
      clientId: clientId,
      resolver: resolver,
      authFetcher: fetcher
    )
  }
}

private let protectedResourceURL =
  "https://pds.example/.well-known/oauth-protected-resource"
private let authorizationServerURL =
  "https://auth.example/.well-known/oauth-authorization-server"
private let revocationURL = "https://auth.example/oauth/revoke"

private func validDIDDocument(
  type: String = "AtprotoPersonalDataServer",
  endpoint: String = "https://pds.example"
) -> DIDDocument {
  let did = try! DID(string: "did:plc:alice")
  return DIDDocument(
    context: [],
    did: FormatString(did),
    service: [
      DocService(
        id: "\(did.rawValue)#atproto_pds",
        type: type,
        serviceEndpoint: endpoint
      )
    ]
  )
}

private actor RevocationResolver: ATPResolver {
  private let document: DIDDocument?
  private var count = 0

  init(document: DIDDocument?) {
    self.document = document
  }

  func resolve(handle _: Handle) async throws -> DID? { nil }

  func resolve(did _: DID) async throws -> DIDDocument? {
    count += 1
    return document
  }

  func resolveCount() -> Int { count }
}

private actor RevocationFetcher: HTTPFetcher {
  private let includeRevocationEndpoint: Bool
  private let revocationStatus: HTTPResponse.Status
  private var requests: [String] = []
  private var revocation: BundledHTTPRequest?

  init(
    includeRevocationEndpoint: Bool,
    revocationStatus: HTTPResponse.Status = .ok
  ) {
    self.includeRevocationEndpoint = includeRevocationEndpoint
    self.revocationStatus = revocationStatus
  }

  func data(for request: BundledHTTPRequest) async throws -> HTTPDataResponse {
    let url = request.request.url!.absoluteString
    requests.append(url)
    let data: Data
    switch url {
    case protectedResourceURL:
      data = protectedResourceMetadata(authorizationServers: ["https://auth.example"])
    case authorizationServerURL:
      data = authorizationServerMetadata(
        revocationEndpoint: includeRevocationEndpoint
      )
    case revocationURL:
      revocation = request
      return HTTPDataResponse(data: Data(), response: HTTPResponse(status: revocationStatus))
    default:
      return HTTPDataResponse(data: Data(), response: HTTPResponse(status: .notFound))
    }
    return HTTPDataResponse(data: data, response: HTTPResponse(status: .ok))
  }

  func requestedURLs() -> [String] { requests }

  func revocationRequest() -> BundledHTTPRequest? { revocation }
}

private func formFields(_ data: Data) -> [String: String] {
  let encoded = String(decoding: data, as: UTF8.self)
  var components = URLComponents()
  components.percentEncodedQuery = encoded
  return Dictionary(
    uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
      item.value.map { (item.name, $0) }
    }
  )
}
