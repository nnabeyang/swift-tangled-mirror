import Crypto
import Foundation
import SwiftAtproto
import TangledLexicons

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum TMBAuthFlowError: Error, Equatable, Sendable {
  case invalidPublicMetadata
  case identityNotResolved
  case authorizationFailed
  case authorizationExpired
  case authorizationTimedOut
  case sessionAlreadyExists
}

extension TMBAuthFlowError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidPublicMetadata: "TMB OAuth public metadata is invalid"
    case .identityNotResolved: "AT Protocol identity could not be resolved"
    case .authorizationFailed: "TMB OAuth authorization failed"
    case .authorizationExpired: "TMB OAuth authorization expired"
    case .authorizationTimedOut: "TMB OAuth authorization timed out"
    case .sessionAlreadyExists: "A TMB OAuth session already exists; log out before signing in again"
    }
  }
}

public protocol TMBPublicDocumentValidating: Sendable {
  func validate(origin: TMBOrigin) async throws
}

public struct TMBPublicDocumentValidator: TMBPublicDocumentValidating, Sendable {
  private let transport: any HTTPTransport

  public init(transport: any HTTPTransport = URLSessionTransport()) {
    self.transport = transport
  }

  public func validate(origin: TMBOrigin) async throws {
    let metadataURL = origin.url.appendingPathComponent("oauth-client-metadata.json")
    let jwksURL = origin.url.appendingPathComponent("oauth/jwks.json")
    let metadata: TMBClientMetadata = try await load(metadataURL)
    let jwks: TMBJWKSet = try await load(jwksURL)
    let expectedCallback = origin.url.appendingPathComponent("oauth/callback").absoluteString
    guard metadata.applicationType == "web",
      metadata.clientID == metadataURL.absoluteString,
      metadata.jwksURI == jwksURL.absoluteString,
      metadata.redirectURIs == [expectedCallback],
      metadata.tokenEndpointAuthMethod == "private_key_jwt",
      metadata.tokenEndpointAuthSigningAlgorithm == "ES256",
      metadata.dpopBoundAccessTokens,
      Set(metadata.scope.split(whereSeparator: \.isWhitespace).map(String.init))
        == ["atproto", "transition:generic"],
      jwks.keys.contains(where: {
        $0.algorithm == "ES256" && $0.curve == "P-256" && $0.keyType == "EC"
          && $0.use == "sig" && !$0.keyID.isEmpty && !$0.x.isEmpty && !$0.y.isEmpty
      })
    else { throw TMBAuthFlowError.invalidPublicMetadata }
  }

  private func load<Value: Decodable>(_ url: URL) async throws -> Value {
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      let (data, response) = try await transport.send(request)
      guard response.statusCode == 200 else { throw TMBAuthFlowError.invalidPublicMetadata }
      return try JSONDecoder().decode(Value.self, from: data)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TMBAuthFlowError {
      throw error
    } catch {
      throw TMBAuthFlowError.invalidPublicMetadata
    }
  }
}

public protocol TMBAuthorizationClient: Sendable {
  func prepareAuthorization(
    _ input: Org.Nnabeyang.TmbPrepareAuthorization_Input
  ) async throws -> Org.Nnabeyang.TmbPrepareAuthorization_Output
  func submitAuthorization(
    _ input: Org.Nnabeyang.TmbSubmitAuthorization_Input
  ) async throws -> Org.Nnabeyang.TmbSubmitAuthorization_Output
  func authorization(flowID: String) async throws -> Org.Nnabeyang.TmbGetAuthorization_Output
  func exchangeAuthorization(
    _ input: Org.Nnabeyang.TmbExchangeAuthorization_Input
  ) async throws -> Org.Nnabeyang.TmbExchangeAuthorization_Output
}

extension TMBClient: TMBAuthorizationClient {
  public func prepareAuthorization(
    _ input: Org.Nnabeyang.TmbPrepareAuthorization_Input
  ) async throws -> Org.Nnabeyang.TmbPrepareAuthorization_Output {
    try await TmbPrepareAuthorization(input: input)
  }

  public func submitAuthorization(
    _ input: Org.Nnabeyang.TmbSubmitAuthorization_Input
  ) async throws -> Org.Nnabeyang.TmbSubmitAuthorization_Output {
    try await TmbSubmitAuthorization(input: input)
  }

  public func authorization(flowID: String) async throws -> Org.Nnabeyang.TmbGetAuthorization_Output {
    try await TmbGetAuthorization(flowId: flowID)
  }

  public func exchangeAuthorization(
    _ input: Org.Nnabeyang.TmbExchangeAuthorization_Input
  ) async throws -> Org.Nnabeyang.TmbExchangeAuthorization_Output {
    try await TmbExchangeAuthorization(input: input)
  }
}

public struct TMBAuthFlow: Sendable {
  private let resolver: any ATPResolver
  private let browser: any BrowserLauncher
  private let publicDocuments: any TMBPublicDocumentValidating
  private let sleep: @Sendable () async throws -> Void
  private let maximumPolls: Int
  private let now: @Sendable () -> Date

  public init(
    resolver: any ATPResolver = URLSessionATPResolver(),
    browser: any BrowserLauncher = .system,
    publicDocuments: any TMBPublicDocumentValidating = TMBPublicDocumentValidator(),
    maximumPolls: Int = 300,
    sleep: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .seconds(1))
    },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.resolver = resolver
    self.browser = browser
    self.publicDocuments = publicDocuments
    self.maximumPolls = maximumPolls
    self.sleep = sleep
    self.now = now
  }

  public func login(
    identifier rawIdentifier: String,
    registration: TMBDeviceRegistration,
    client: any TMBAuthorizationClient
  ) async throws -> TMBSession {
    try await publicDocuments.validate(origin: registration.origin)
    let identity = try await resolve(rawIdentifier)
    let proofKey = TMBProofKey()
    let verifier = randomBase64URL(byteCount: 32)
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).tmbAuthBase64URL()
    let prepared = try await client.prepareAuthorization(
      try .make(
        dpopPublicKey: proofKey.publicJWK,
        identifier: rawIdentifier,
        pkceChallenge: challenge,
        scope: "atproto transition:generic"
      ))

    var submissionProof = prepared.proof
    var submitted: Org.Nnabeyang.TmbSubmitAuthorization_Output?
    for _ in 0 ..< 3 {
      let output = try await client.submitAuthorization(
        try .make(
          dpopProof: proofKey.dpopProof(method: "POST", proofRequest: submissionProof),
          flowId: prepared.flowId
        ))
      if output.status == .proofrequired, let proof = output.proof {
        submissionProof = proof
        continue
      }
      submitted = output
      break
    }
    guard let submitted, submitted.status == .ready,
      let rawAuthorizationURL = submitted.authorizationUrl?.rawValue,
      let authorizationURL = URL(string: rawAuthorizationURL),
      var exchangeProof = submitted.proof
    else { throw TMBAuthFlowError.authorizationFailed }

    try await browser.open(authorizationURL)
    try await waitForAuthorization(flowID: prepared.flowId, client: client)

    var exchanged: Org.Nnabeyang.TmbExchangeAuthorization_Output?
    for _ in 0 ..< 3 {
      let output = try await client.exchangeAuthorization(
        try .make(
          dpopProof: proofKey.dpopProof(method: "POST", proofRequest: exchangeProof),
          flowId: prepared.flowId,
          pkceVerifier: verifier
        ))
      if output.status == .proofrequired, let proof = output.proof {
        exchangeProof = proof
        continue
      }
      exchanged = output
      break
    }
    guard let exchanged, exchanged.status == .complete, let result = exchanged.session,
      let refreshProof = exchanged.proof, result.expiresIn > 0
    else { throw TMBAuthFlowError.authorizationFailed }
    return try TMBSession(
      instance: registration.instance,
      origin: registration.origin,
      accountDID: identity.did,
      handle: identity.handle,
      accessToken: result.accessToken,
      tokenType: result.tokenType,
      expiresAt: now().addingTimeInterval(TimeInterval(result.expiresIn)),
      sessionID: result.sessionId,
      proofKey: proofKey,
      refreshProof: refreshProof
    )
  }

  private func waitForAuthorization(
    flowID: String,
    client: any TMBAuthorizationClient
  ) async throws {
    for _ in 0 ..< maximumPolls {
      let output = try await client.authorization(flowID: flowID)
      switch output.status {
      case .succeeded: return
      case .failed: throw TMBAuthFlowError.authorizationFailed
      case .expired: throw TMBAuthFlowError.authorizationExpired
      case .pending, ._other: try await sleep()
      }
    }
    throw TMBAuthFlowError.authorizationTimedOut
  }

  private func resolve(_ rawIdentifier: String) async throws -> (did: String, handle: String) {
    do {
      let identifier = try AtIdentifier(string: rawIdentifier)
      guard let resolved = try await resolver.verifiedResolve(atIdentifier: identifier) else {
        throw TMBAuthFlowError.identityNotResolved
      }
      let handle =
        resolved.verifiedHandle == .invalid
        ? rawIdentifier
        : resolved.verifiedHandle.rawValue
      return (resolved.did.rawValue, handle)
    } catch let error as TMBAuthFlowError {
      throw error
    } catch {
      throw TMBAuthFlowError.identityNotResolved
    }
  }
}

private struct TMBClientMetadata: Decodable {
  let applicationType: String
  let clientID: String
  let dpopBoundAccessTokens: Bool
  let jwksURI: String
  let redirectURIs: [String]
  let scope: String
  let tokenEndpointAuthMethod: String
  let tokenEndpointAuthSigningAlgorithm: String

  enum CodingKeys: String, CodingKey {
    case applicationType = "application_type"
    case clientID = "client_id"
    case dpopBoundAccessTokens = "dpop_bound_access_tokens"
    case jwksURI = "jwks_uri"
    case redirectURIs = "redirect_uris"
    case scope
    case tokenEndpointAuthMethod = "token_endpoint_auth_method"
    case tokenEndpointAuthSigningAlgorithm = "token_endpoint_auth_signing_alg"
  }
}

private struct TMBJWKSet: Decodable {
  let keys: [TMBPublicJWK]
}

private struct TMBPublicJWK: Decodable {
  let algorithm: String
  let curve: String
  let keyID: String
  let keyType: String
  let use: String
  let x: String
  let y: String

  enum CodingKeys: String, CodingKey {
    case algorithm = "alg"
    case curve = "crv"
    case keyID = "kid"
    case keyType = "kty"
    case use, x, y
  }
}

private func randomBase64URL(byteCount: Int) -> String {
  var generator = SystemRandomNumberGenerator()
  let bytes = (0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  return Data(bytes).tmbAuthBase64URL()
}

extension Data {
  fileprivate func tmbAuthBase64URL() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
