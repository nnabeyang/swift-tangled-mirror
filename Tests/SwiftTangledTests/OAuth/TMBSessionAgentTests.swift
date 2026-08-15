import Foundation
import SwiftAtproto
import TangledLexicons
import Testing

@testable import SwiftTangled

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct TMBSessionAgentTests {
  @Test func validAccessTokenUsesDirectPDSWithoutTMBRequest() async throws {
    let control = RecordingTMBSessionControl()
    let transport = RecordingTMBPDSTransport(responses: [
      .init(status: 200, body: #"{"did":"did:plc:alice"}"#)
    ])
    let agent = TMBSessionAgent(
      session: try tmbSession(expiresAt: Date(timeIntervalSince1970: 2_000)),
      store: MemoryTMBSessionStore(), tmb: control,
      resolver: TMBSessionResolver(), transport: transport,
      now: { Date(timeIntervalSince1970: 1_000) })

    let data = try await agent.response(tmbGetSessionComponents())
    #expect(String(decoding: data, as: UTF8.self).contains("did:plc:alice"))
    #expect(await control.refreshCount == 0)
    let request = try #require(await transport.requests.first)
    #expect(request.url?.absoluteString == "https://pds.example/xrpc/com.atproto.server.getSession")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP access-one")
    #expect(request.value(forHTTPHeaderField: "DPoP") != nil)
  }

  @Test func nonceChallengeRetriesPDSAndPersistsNonceWithoutRefreshing() async throws {
    let control = RecordingTMBSessionControl()
    let store = MemoryTMBSessionStore()
    let transport = RecordingTMBPDSTransport(responses: [
      .init(status: 401, body: #"{"error":"use_dpop_nonce"}"#, nonce: "pds-nonce"),
      .init(status: 200, body: #"{"did":"did:plc:alice"}"#),
    ])
    let agent = TMBSessionAgent(
      session: try tmbSession(expiresAt: Date(timeIntervalSince1970: 2_000)),
      store: store, tmb: control, resolver: TMBSessionResolver(), transport: transport,
      now: { Date(timeIntervalSince1970: 1_000) })

    _ = try await agent.response(tmbGetSessionComponents())
    #expect(await transport.requests.count == 2)
    #expect(store.session?.pdsNonce == "pds-nonce")
    #expect(await control.refreshCount == 0)
  }

  @Test func concurrentExpiredRequestsShareOneRefresh() async throws {
    let control = RecordingTMBSessionControl(delay: .milliseconds(20))
    let store = MemoryTMBSessionStore()
    let transport = RecordingTMBPDSTransport(
      responses: (0 ..< 20).map { _ in
        .init(status: 200, body: #"{"did":"did:plc:alice"}"#)
      })
    let agent = TMBSessionAgent(
      session: try tmbSession(expiresAt: Date(timeIntervalSince1970: 900)),
      store: store, tmb: control, resolver: TMBSessionResolver(), transport: transport,
      now: { Date(timeIntervalSince1970: 1_000) })

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 20 {
        group.addTask { _ = try await agent.response(tmbGetSessionComponents()) }
      }
      try await group.waitForAll()
    }

    #expect(await control.refreshCount == 1)
    #expect(store.session?.accessToken == "access-two")
    #expect(await transport.requests.count == 20)
  }
}

private func tmbSession(expiresAt: Date) throws -> TMBSession {
  try TMBSession(
    instance: "validation", origin: TMBOrigin("https://tmb.example"),
    accountDID: "did:plc:alice", handle: "alice.example",
    accessToken: "access-one", tokenType: "DPoP", expiresAt: expiresAt,
    sessionID: "session-one", proofKey: TMBProofKey(),
    refreshProof: .init(
      endpoint: .init(rawValue: "https://issuer.example/token"), nonce: "refresh-nonce"))
}

private func tmbGetSessionComponents() -> XRPCRequestComponents {
  XRPCRequestComponents(
    nsId: "com.atproto.server.getSession", queryItems: [], headers: [:], method: .get,
    body: nil)
}

private final class MemoryTMBSessionStore: TMBSessionStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var value: TMBSession?
  var session: TMBSession? { lock.withLock { value } }
  func load() throws -> TMBSession? { session }
  func write(_ session: TMBSession) throws { lock.withLock { value = session } }
  func clear() throws { lock.withLock { value = nil } }
}

private actor RecordingTMBSessionControl: TMBSessionControlling {
  private(set) var refreshCount = 0
  let delay: Duration?

  init(delay: Duration? = nil) { self.delay = delay }

  func refresh(
    _: Org.Nnabeyang.TmbRefreshSession_Input
  ) async throws -> Org.Nnabeyang.TmbRefreshSession_Output {
    refreshCount += 1
    if let delay { try await Task.sleep(for: delay) }
    return .init(
      proof: .init(
        endpoint: .init(rawValue: "https://issuer.example/token"), nonce: "next-nonce"),
      session: .init(
        accessToken: "access-two", expiresIn: 300, sessionId: "session-one",
        tokenType: "DPoP"),
      status: .complete)
  }

  func revoke(sessionID _: String) async throws -> Bool { true }
}

private struct TMBSessionResolver: ATPResolver {
  func resolve(handle _: Handle) async throws -> DID? { nil }
  func resolve(did: DID) async throws -> DIDDocument? {
    DIDDocument(
      context: ["https://www.w3.org/ns/did/v1"], did: .init(did),
      service: [
        .init(
          id: "#atproto_pds", type: "AtprotoPersonalDataServer",
          serviceEndpoint: "https://pds.example")
      ])
  }
}

private actor RecordingTMBPDSTransport: HTTPTransport {
  struct Response: Sendable {
    let status: Int
    let body: String
    var nonce: String? = nil
  }

  private var responses: [Response]
  private(set) var requests: [URLRequest] = []

  init(responses: [Response]) { self.responses = responses }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let response = responses.removeFirst()
    let headers = response.nonce.map { ["DPoP-Nonce": $0] } ?? [:]
    return (
      Data(response.body.utf8),
      HTTPURLResponse(
        url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
        headerFields: headers)!
    )
  }
}
