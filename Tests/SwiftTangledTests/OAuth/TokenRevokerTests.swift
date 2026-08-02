import Foundation
import GermConvenience
import HTTPTypes
import OAuth4Swift
import SwiftAtproto
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@testable import SwiftTangled

@Suite(.serialized) struct TokenRevokerTests {
  @Test func revokesRefreshTokenAtDiscoveredAuthorizationServer() async throws {
    RevocationURLProtocol.reset(statusCode: 200)
    let resolver = RevocationResolver(document: validDIDDocument())
    let fetcher = RevocationMetadataFetcher(includeRevocationEndpoint: true)

    try await makeRevoker(resolver: resolver, fetcher: fetcher).revoke()

    let request = try #require(RevocationURLProtocol.recordedRequests().first)
    #expect(request.url?.absoluteString == "https://auth.example/oauth/revoke")
    #expect(request.httpMethod == "POST")
    #expect(
      request.value(forHTTPHeaderField: "Content-Type")
        == "application/x-www-form-urlencoded"
    )
    let fields = formFields(try #require(request.httpBody))
    #expect(fields["token"] == "private-refresh-token")
    #expect(fields["token_type_hint"] == "refresh_token")
    #expect(fields["client_id"] == "https://client.example/metadata.json")
  }

  @Test func missingRefreshTokenSkipsResolutionDiscoveryAndRequest() async throws {
    RevocationURLProtocol.reset(statusCode: 200)
    let resolver = RevocationResolver(document: validDIDDocument())
    let fetcher = RevocationMetadataFetcher(includeRevocationEndpoint: true)
    let session = try SessionStoreTestHelpers.makeStoredSession(refreshToken: nil)

    try await makeRevoker(session: session, resolver: resolver, fetcher: fetcher).revoke()

    #expect(await resolver.resolveCount() == 0)
    #expect(await fetcher.requestedURLs().isEmpty)
    #expect(RevocationURLProtocol.recordedRequests().isEmpty)
  }

  @Test func missingRevocationEndpointIsANoOp() async throws {
    RevocationURLProtocol.reset(statusCode: 200)
    let resolver = RevocationResolver(document: validDIDDocument())
    let fetcher = RevocationMetadataFetcher(includeRevocationEndpoint: false)

    try await makeRevoker(resolver: resolver, fetcher: fetcher).revoke()

    #expect(await fetcher.requestedURLs().count == 2)
    #expect(RevocationURLProtocol.recordedRequests().isEmpty)
  }

  @Test func missingDIDDocumentAndInvalidPDSServicesFailBeforeDiscovery() async throws {
    for document in [
      nil,
      validDIDDocument(type: "NotAPersonalDataServer"),
      validDIDDocument(endpoint: "not a URL"),
    ] {
      RevocationURLProtocol.reset(statusCode: 200)
      let resolver = RevocationResolver(document: document)
      let fetcher = RevocationMetadataFetcher(includeRevocationEndpoint: true)

      await #expect(throws: (any Error).self) {
        try await makeRevoker(resolver: resolver, fetcher: fetcher).revoke()
      }
      #expect(await fetcher.requestedURLs().isEmpty)
      #expect(RevocationURLProtocol.recordedRequests().isEmpty)
    }
  }

  @Test func revocationFailureDoesNotExposeTheRefreshToken() async throws {
    RevocationURLProtocol.reset(statusCode: 503)
    let resolver = RevocationResolver(document: validDIDDocument())
    let fetcher = RevocationMetadataFetcher(includeRevocationEndpoint: true)

    do {
      try await makeRevoker(resolver: resolver, fetcher: fetcher).revoke()
      Issue.record("expected revocation failure")
    } catch {
      #expect(!String(describing: error).contains("private-refresh-token"))
      #expect(!error.localizedDescription.contains("private-refresh-token"))
      guard case TangledError.serverStatus(let status, _) = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(status == 503)
    }
  }

  private func makeRevoker(
    session: StoredSession? = nil,
    resolver: RevocationResolver,
    fetcher: RevocationMetadataFetcher
  ) throws -> TokenRevoker {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RevocationURLProtocol.self]
    return TokenRevoker(
      session: try session
        ?? SessionStoreTestHelpers.makeStoredSession(
          refreshToken: "private-refresh-token"
        ),
      clientId: "https://client.example/metadata.json",
      resolver: resolver,
      authFetcher: fetcher,
      urlSession: URLSession(configuration: configuration)
    )
  }
}

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

private actor RevocationMetadataFetcher: HTTPFetcher {
  private let includeRevocationEndpoint: Bool
  private var requests: [String] = []

  init(includeRevocationEndpoint: Bool) {
    self.includeRevocationEndpoint = includeRevocationEndpoint
  }

  func data(for request: BundledHTTPRequest) async throws -> HTTPDataResponse {
    let url = request.request.url!.absoluteString
    requests.append(url)
    let data: Data
    switch url {
    case "https://pds.example/.well-known/oauth-protected-resource":
      data = protectedResourceMetadata(authorizationServers: ["https://auth.example"])
    case "https://auth.example/.well-known/oauth-authorization-server":
      data = authorizationServerMetadata(
        revocationEndpoint: includeRevocationEndpoint
      )
    default:
      return HTTPDataResponse(data: Data(), response: HTTPResponse(status: .notFound))
    }
    return HTTPDataResponse(data: data, response: HTTPResponse(status: .ok))
  }

  func requestedURLs() -> [String] { requests }
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

private final class RevocationURLProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requests: [URLRequest] = []
  nonisolated(unsafe) private static var statusCode = 200

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var recordedRequest = request
    if recordedRequest.httpBody == nil, let stream = recordedRequest.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var body = Data()
      let bufferSize = 1_024
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        guard count > 0 else { break }
        body.append(buffer, count: count)
      }
      recordedRequest.httpBody = body
    }
    Self.lock.lock()
    Self.requests.append(recordedRequest)
    let statusCode = Self.statusCode
    Self.lock.unlock()
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func reset(statusCode: Int) {
    lock.lock()
    requests = []
    self.statusCode = statusCode
    lock.unlock()
  }

  static func recordedRequests() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}
