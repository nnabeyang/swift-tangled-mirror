import Foundation
import HTTPTypes
import SwiftAtproto
import TangledLexicons

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum TMBSessionAgentError: Error, Equatable, Sendable {
  case sessionMissing
  case sessionRevoked
  case pdsUnavailable
  case invalidResponse
}

extension TMBSessionAgentError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .sessionMissing: "TMB OAuth session is unavailable; sign in interactively"
    case .sessionRevoked: "TMB OAuth session was revoked; sign in interactively"
    case .pdsUnavailable: "The account PDS is unavailable"
    case .invalidResponse: "The account PDS returned an invalid response"
    }
  }
}

public protocol TMBSessionControlling: Sendable {
  func refresh(
    _ input: Org.Nnabeyang.TmbRefreshSession_Input
  ) async throws -> Org.Nnabeyang.TmbRefreshSession_Output
  func revoke(sessionID: String) async throws -> Bool
}

extension TMBClient: TMBSessionControlling {
  public func refresh(
    _ input: Org.Nnabeyang.TmbRefreshSession_Input
  ) async throws -> Org.Nnabeyang.TmbRefreshSession_Output {
    try await TmbRefreshSession(input: input)
  }

  public func revoke(sessionID: String) async throws -> Bool {
    try await TmbRevokeSession(input: .init(sessionId: sessionID)).revoked
  }
}

public actor TMBSessionAgent: XRPCCallable {
  public nonisolated let did: String

  private var session: TMBSession
  private let store: any TMBSessionStoring
  private let tmb: any TMBSessionControlling
  private let resolver: any ATPResolver
  private let transport: any HTTPTransport
  private let now: @Sendable () -> Date
  private var pdsURL: URL?
  private var refreshTask: Task<TMBSession, Error>?

  public init(
    session: TMBSession,
    store: any TMBSessionStoring,
    tmb: any TMBSessionControlling,
    resolver: any ATPResolver = URLSessionATPResolver(),
    transport: any HTTPTransport = URLSessionTransport(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.session = session
    self.store = store
    self.tmb = tmb
    self.resolver = resolver
    self.transport = transport
    self.now = now
    did = session.accountDID
  }

  public nonisolated func getProxy(nsid _: String) -> String? { nil }

  public func response(_ components: XRPCRequestComponents) async throws -> Data {
    for authorizationAttempt in 0 ... 1 {
      let active = try await usableSession(forceRefresh: authorizationAttempt == 1)
      let result = try await send(components, using: active)
      if result.response.statusCode == 401, authorizationAttempt == 0 { continue }
      guard (200 ... 299).contains(result.response.statusCode) else {
        throw mapFailure(data: result.data, response: result.response)
      }
      return result.data
    }
    throw TMBSessionAgentError.sessionRevoked
  }

  public func forceRefresh() async throws {
    _ = try await usableSession(forceRefresh: true)
  }

  public func snapshot() -> TMBSession { session }

  private func usableSession(forceRefresh: Bool) async throws -> TMBSession {
    try synchronizeFromStore()
    if !forceRefresh, session.expiresAt.timeIntervalSince(now()) > 30 { return session }
    if let refreshTask { return try await refreshTask.value }
    let current = session
    let tmb = self.tmb
    let store = self.store
    let now = self.now
    let task = Task<TMBSession, Error> {
      do {
        var proof = current.refreshProof
        for _ in 0 ..< 3 {
          let output = try await tmb.refresh(
            try .make(
              dpopProof: current.proofKey.dpopProof(method: "POST", proofRequest: proof),
              sessionId: current.sessionID
            ))
          if output.status == .proofrequired, let next = output.proof {
            proof = next
            continue
          }
          guard output.status == .complete, let result = output.session,
            let nextProof = output.proof, result.expiresIn > 0
          else { throw TMBSessionAgentError.sessionRevoked }
          let updated = try TMBSession(
            instance: current.instance,
            origin: current.origin,
            accountDID: current.accountDID,
            handle: current.handle,
            accessToken: result.accessToken,
            tokenType: result.tokenType,
            expiresAt: now().addingTimeInterval(TimeInterval(result.expiresIn)),
            sessionID: result.sessionId,
            proofKey: current.proofKey,
            refreshProof: nextProof,
            pdsNonce: current.pdsNonce
          )
          if try store.replace(updated, ifCurrentRevision: current.revision) { return updated }
          guard let latest = try store.load() else { throw TMBSessionAgentError.sessionMissing }
          return latest
        }
        throw TMBSessionAgentError.sessionRevoked
      } catch {
        if let latest = try store.load(), latest.revision != current.revision { return latest }
        throw error
      }
    }
    refreshTask = task
    do {
      let updated = try await task.value
      session = updated
      refreshTask = nil
      return updated
    } catch {
      refreshTask = nil
      throw error
    }
  }

  private func send(
    _ components: XRPCRequestComponents,
    using initial: TMBSession
  ) async throws -> (data: Data, response: HTTPURLResponse) {
    let endpoint = try await endpoint(for: components)
    var active = initial
    for nonceAttempt in 0 ... 1 {
      var request = URLRequest(url: endpoint, timeoutInterval: 20)
      request.httpMethod = components.method.rawValue
      request.httpBody = components.body
      for field in components.headers {
        let name = field.name.rawName.lowercased()
        guard name != "authorization", name != "dpop" else {
          throw TMBSessionAgentError.invalidResponse
        }
        request.addValue(field.value, forHTTPHeaderField: field.name.rawName)
      }
      request.setValue("DPoP \(active.accessToken)", forHTTPHeaderField: "Authorization")
      request.setValue(
        try active.proofKey.dpopProof(
          method: components.method.rawValue,
          endpoint: endpoint,
          nonce: active.pdsNonce,
          accessToken: active.accessToken
        ),
        forHTTPHeaderField: "DPoP"
      )
      let data: Data
      let response: HTTPURLResponse
      do { (data, response) = try await transport.send(request) } catch is CancellationError {
        throw CancellationError()
      } catch { throw TMBSessionAgentError.pdsUnavailable }
      let responseNonce = response.value(forHTTPHeaderField: "DPoP-Nonce")
        .flatMap { $0.isEmpty ? nil : $0 }
      if let responseNonce, responseNonce != active.pdsNonce {
        let updated = try TMBSession(
          instance: active.instance, origin: active.origin,
          accountDID: active.accountDID, handle: active.handle,
          accessToken: active.accessToken, tokenType: active.tokenType,
          expiresAt: active.expiresAt, sessionID: active.sessionID,
          proofKey: active.proofKey, refreshProof: active.refreshProof,
          pdsNonce: responseNonce)
        if try store.replace(updated, ifCurrentRevision: active.revision) {
          session = updated
          active = updated
        } else if let latest = try store.load() {
          session = latest
          active = latest
        }
        if nonceAttempt == 0, response.statusCode == 400 || response.statusCode == 401 {
          continue
        }
      }
      return (data, response)
    }
    throw TMBSessionAgentError.invalidResponse
  }

  private func synchronizeFromStore() throws {
    guard let latest = try store.load() else { return }
    if latest.revision != session.revision { session = latest }
  }

  private func endpoint(for components: XRPCRequestComponents) async throws -> URL {
    let baseURL: URL
    if let pdsURL {
      baseURL = pdsURL
    } else {
      guard let did = try? DID(string: session.accountDID),
        let document = try await resolver.resolve(did: did),
        let resolved = try? document.pdsUrl
      else { throw TMBSessionAgentError.pdsUnavailable }
      pdsURL = resolved
      baseURL = resolved
    }
    let endpoint = baseURL.appendingPathComponent("xrpc/\(components.nsId)")
    guard var values = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw TMBSessionAgentError.invalidResponse
    }
    if !components.queryItems.isEmpty {
      values.percentEncodedQueryItems = components.queryItems
    }
    guard let url = values.url else { throw TMBSessionAgentError.invalidResponse }
    return url
  }

  private func mapFailure(data: Data, response: HTTPURLResponse) -> any Error {
    let failure = try? JSONDecoder().decode(TMBPDSFailure.self, from: data)
    let message = failure?.message ?? failure?.error
    switch response.statusCode {
    case 400: return TangledError.invalidRequest(message)
    case 401: return TMBSessionAgentError.sessionRevoked
    case 403: return TangledError.forbidden(message)
    case 404: return TangledError.notFound(message)
    case 429:
      return TangledError.rateLimited(
        retryAfter: RetryAfterHeader.parse(response.value(forHTTPHeaderField: "Retry-After")),
        message: message)
    case 502, 503, 504: return TMBSessionAgentError.pdsUnavailable
    default: return TangledError.serverStatus(response.statusCode, message)
    }
  }
}

private struct TMBPDSFailure: Decodable {
  let error: String?
  let message: String?
}
