import Foundation
import GermConvenience
import HTTPTypes
import OAuth4Swift
import SwiftAtproto
import Testing

@testable import SwiftTangled

@Suite struct AtprotoOAuthAgentResponseTests {
  @Test func mapsAnXRPCErrorBodyToAnOAuthError() async throws {
    let agent = try makeAgent(
      fetcher: XRPCFetcher(
        xrpc: .init(
          status: .badRequest,
          data: Data(#"{"error":"InvalidSwap","message":"record changed"}"#.utf8)
        )
      )
    )

    do {
      _ = try await agent.response(putRecordComponents)
      Issue.record("expected an OAuth error")
    } catch OAuth.Errors.oauthError(let response, let status) {
      #expect(response.error == "InvalidSwap")
      #expect(status == .badRequest)
    }
  }

  @Test func keepsTheRawResponseWhenTheBodyIsNotAnOAuthError() async throws {
    let agent = try makeAgent(
      fetcher: XRPCFetcher(
        xrpc: .init(status: .internalServerError, data: Data("upstream exploded".utf8))
      )
    )

    do {
      _ = try await agent.response(putRecordComponents)
      Issue.record("expected an HTTP response error")
    } catch OAuth.Errors.httpResponse(let response) {
      #expect(response.response.status == .internalServerError)
      #expect(String(decoding: response.data, as: UTF8.self) == "upstream exploded")
    }
  }

  @Test func doesNotHandBackAnErrorBodyThatSurvivedTheRefresh() async throws {
    let fetcher = XRPCFetcher(
      xrpc: .init(status: .unauthorized, data: Data(#"{"error":"ExpiredToken"}"#.utf8))
    )
    let agent = try makeAgent(fetcher: fetcher)

    do {
      _ = try await agent.response(putRecordComponents)
      Issue.record("expected an OAuth error")
    } catch OAuth.Errors.oauthError(let response, let status) {
      #expect(response.error == "ExpiredToken")
      #expect(status == .unauthorized)
    }
    #expect(await fetcher.refreshCount() == 1)
  }

  private func makeAgent(fetcher: XRPCFetcher) throws -> AtprotoOAuthAgent {
    let session = try SessionStoreTestHelpers.makeStoredSession(
      did: accountDID,
      includeDPoPKey: true
    )
    let (agent, _) = try AtprotoOAuthAgent.restore(
      archive: .init(did: session.did, session: session.archive),
      clientId: "https://client.example/metadata.json",
      authFetcher: fetcher,
      atprotoResolver: AgentResolver(),
      delegate: nil
    )
    return agent
  }
}

private let accountDID = "did:plc:alice"
private let xrpcURL = "https://pds.example/xrpc/com.atproto.repo.putRecord"

private var putRecordComponents: XRPCRequestComponents {
  .init(
    nsId: "com.atproto.repo.putRecord",
    queryItems: [],
    headers: HTTPFields(),
    method: .post,
    body: Data("{}".utf8)
  )
}

private actor AgentResolver: ATPResolver {
  func resolve(handle _: Handle) async throws -> DID? { nil }

  func resolve(did: DID) async throws -> DIDDocument? {
    DIDDocument(
      context: [],
      did: FormatString(did),
      service: [
        DocService(
          id: "\(did.rawValue)#atproto_pds",
          type: "AtprotoPersonalDataServer",
          serviceEndpoint: "https://pds.example"
        )
      ]
    )
  }
}

private actor XRPCFetcher: HTTPFetcher {
  struct Stub: Sendable {
    let status: HTTPResponse.Status
    let data: Data
  }

  private let xrpc: Stub
  private var refreshes = 0

  init(xrpc: Stub) {
    self.xrpc = xrpc
  }

  func data(for request: BundledHTTPRequest) async throws -> HTTPDataResponse {
    // constructUrl always sets percentEncodedQueryItems, so a request without
    // query items still carries a trailing "?".
    let url = request.request.url!
    switch "https://\(url.host ?? "")\(url.path)" {
    case xrpcURL:
      return HTTPDataResponse(
        data: xrpc.data,
        response: HTTPResponse(status: xrpc.status)
      )
    case "https://pds.example/.well-known/oauth-protected-resource":
      return .ok(protectedResourceMetadata(authorizationServers: ["https://auth.example"]))
    case "https://auth.example/.well-known/oauth-authorization-server":
      return .ok(authorizationServerMetadata())
    case "https://auth.example/oauth/token":
      refreshes += 1
      return .ok(refreshedTokenResponse())
    default:
      return HTTPDataResponse(data: Data(), response: HTTPResponse(status: .notFound))
    }
  }

  func refreshCount() -> Int { refreshes }
}

extension HTTPDataResponse {
  fileprivate static func ok(_ data: Data) -> HTTPDataResponse {
    .init(data: data, response: HTTPResponse(status: .ok))
  }
}

private func refreshedTokenResponse() -> Data {
  let object: [String: Any] = [
    "access_token": "refreshed-access",
    "refresh_token": "refreshed-refresh",
    "token_type": "DPoP",
    "expires_in": 3_600,
    "scope": "atproto",
    "sub": accountDID,
  ]
  return try! JSONSerialization.data(withJSONObject: object)
}
