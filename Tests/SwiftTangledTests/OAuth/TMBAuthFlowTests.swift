import Foundation
import SwiftAtproto
import TangledLexicons
import Testing

@testable import SwiftTangled

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct TMBAuthFlowTests {
  @Test func validatesConfidentialWebClientDocuments() async throws {
    let transport = TMBMetadataTransport(responses: [
      #"{"application_type":"web","client_id":"https://tmb.example/oauth-client-metadata.json","dpop_bound_access_tokens":true,"jwks_uri":"https://tmb.example/oauth/jwks.json","redirect_uris":["https://tmb.example/oauth/callback"],"scope":"atproto transition:generic","token_endpoint_auth_method":"private_key_jwt","token_endpoint_auth_signing_alg":"ES256"}"#,
      #"{"keys":[{"alg":"ES256","crv":"P-256","kid":"key-one","kty":"EC","use":"sig","x":"x-value","y":"y-value"}]}"#,
    ])
    try await TMBPublicDocumentValidator(transport: transport).validate(
      origin: TMBOrigin("https://tmb.example"))
    #expect(await transport.paths == ["/oauth-client-metadata.json", "/oauth/jwks.json"])
  }

  @Test func rejectsPublicClientMetadata() async throws {
    let transport = TMBMetadataTransport(responses: [
      #"{"application_type":"native","client_id":"https://tmb.example/oauth-client-metadata.json","dpop_bound_access_tokens":true,"jwks_uri":"https://tmb.example/oauth/jwks.json","redirect_uris":["https://tmb.example/oauth/callback"],"scope":"atproto transition:generic","token_endpoint_auth_method":"none","token_endpoint_auth_signing_alg":"ES256"}"#,
      #"{"keys":[]}"#,
    ])
    await #expect(throws: TMBAuthFlowError.invalidPublicMetadata) {
      try await TMBPublicDocumentValidator(transport: transport).validate(
        origin: TMBOrigin("https://tmb.example"))
    }
  }

  @Test func completesProofChallengesPollingAndExchange() async throws {
    let client = StubTMBAuthorizationClient()
    let browser = RecordingTMBBrowser()
    let flow = TMBAuthFlow(
      resolver: StubTMBResolver(),
      browser: browser,
      publicDocuments: AcceptingTMBPublicDocuments(),
      maximumPolls: 3,
      sleep: {},
      now: { Date(timeIntervalSince1970: 1_000) }
    )
    let session = try await flow.login(
      identifier: "alice.example",
      registration: try tmbRegistration(),
      client: client
    )

    #expect(session.accountDID == "did:plc:alice")
    #expect(session.handle == "alice.example")
    #expect(session.accessToken == "access-token")
    #expect(session.expiresAt == Date(timeIntervalSince1970: 1_300))
    #expect(await browser.openedURL == URL(string: "https://issuer.example/authorize"))
    #expect(await client.submitCount == 2)
    #expect(await client.pollCount == 2)
    #expect(await client.exchangeCount == 2)
  }

  @Test func reportsExpiredAndTimedOutAuthorization() async throws {
    let expired = StubTMBAuthorizationClient(pollStatuses: [.expired])
    let expiredFlow = TMBAuthFlow(
      resolver: StubTMBResolver(), browser: RecordingTMBBrowser(),
      publicDocuments: AcceptingTMBPublicDocuments(), maximumPolls: 1, sleep: {})
    await #expect(throws: TMBAuthFlowError.authorizationExpired) {
      _ = try await expiredFlow.login(
        identifier: "alice.example", registration: try tmbRegistration(), client: expired)
    }

    let pending = StubTMBAuthorizationClient(pollStatuses: [.pending, .pending])
    let timedFlow = TMBAuthFlow(
      resolver: StubTMBResolver(), browser: RecordingTMBBrowser(),
      publicDocuments: AcceptingTMBPublicDocuments(), maximumPolls: 2, sleep: {})
    await #expect(throws: TMBAuthFlowError.authorizationTimedOut) {
      _ = try await timedFlow.login(
        identifier: "alice.example", registration: try tmbRegistration(), client: pending)
    }
  }
}

private actor TMBMetadataTransport: HTTPTransport {
  private var responses: [String]
  private(set) var paths: [String] = []

  init(responses: [String]) { self.responses = responses }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    paths.append(request.url?.path ?? "")
    let body = responses.removeFirst()
    return (
      Data(body.utf8),
      HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
    )
  }
}

private func tmbRegistration() throws -> TMBDeviceRegistration {
  try TMBDeviceRegistration(
    instance: "validation",
    origin: TMBOrigin("https://tmb.example"),
    credentials: TMBDeviceCredentials(
      deviceID: "device-one", nonce: nil, proofKey: TMBProofKey())
  )
}

private struct AcceptingTMBPublicDocuments: TMBPublicDocumentValidating {
  func validate(origin _: TMBOrigin) async throws {}
}

private actor RecordingTMBBrowser: BrowserLauncher {
  private(set) var openedURL: URL?
  func open(_ url: URL) async throws { openedURL = url }
}

private struct StubTMBResolver: ATPResolver {
  func resolve(handle _: Handle) async throws -> DID? { try DID(string: "did:plc:alice") }
  func resolve(did _: DID) async throws -> DIDDocument? {
    DIDDocument(
      context: ["https://www.w3.org/ns/did/v1"],
      did: .init(rawValue: "did:plc:alice"),
      alsoKnownAs: ["at://alice.example"],
      service: [
        .init(
          id: "#atproto_pds", type: "AtprotoPersonalDataServer",
          serviceEndpoint: "https://pds.example")
      ])
  }
}

private actor StubTMBAuthorizationClient: TMBAuthorizationClient {
  private var polls: [Org.Nnabeyang.TmbGetAuthorization_Output_Status]
  private(set) var submitCount = 0
  private(set) var pollCount = 0
  private(set) var exchangeCount = 0

  init(pollStatuses: [Org.Nnabeyang.TmbGetAuthorization_Output_Status] = [.pending, .succeeded]) {
    polls = pollStatuses
  }

  func prepareAuthorization(
    _ input: Org.Nnabeyang.TmbPrepareAuthorization_Input
  ) async throws -> Org.Nnabeyang.TmbPrepareAuthorization_Output {
    #expect(input.scope == "atproto transition:generic")
    return .init(flowId: "flow-one", proof: proof("par-one"))
  }

  func submitAuthorization(
    _: Org.Nnabeyang.TmbSubmitAuthorization_Input
  ) async throws -> Org.Nnabeyang.TmbSubmitAuthorization_Output {
    submitCount += 1
    if submitCount == 1 { return .init(proof: proof("par-two"), status: .proofrequired) }
    return .init(
      authorizationUrl: .init(rawValue: "https://issuer.example/authorize"),
      proof: proof("token-one"), status: .ready)
  }

  func authorization(flowID _: String) async throws -> Org.Nnabeyang.TmbGetAuthorization_Output {
    pollCount += 1
    return .init(status: polls.removeFirst())
  }

  func exchangeAuthorization(
    _: Org.Nnabeyang.TmbExchangeAuthorization_Input
  ) async throws -> Org.Nnabeyang.TmbExchangeAuthorization_Output {
    exchangeCount += 1
    if exchangeCount == 1 {
      return .init(proof: proof("token-two"), status: .proofrequired)
    }
    return .init(
      proof: proof("refresh-one"),
      session: .init(
        accessToken: "access-token", expiresIn: 300, sessionId: "session-one",
        tokenType: "DPoP"),
      status: .complete)
  }

  private func proof(_ nonce: String) -> Org.Nnabeyang.TmbDefs_ProofRequest {
    .init(endpoint: .init(rawValue: "https://issuer.example/token"), nonce: nonce)
  }
}
