import Crypto
import Foundation
import TangledLexicons

public struct TMBProofKey: Sendable {
  private let key: P256.Signing.PrivateKey

  public init() {
    key = P256.Signing.PrivateKey()
  }

  public init(rawRepresentation: Data) throws {
    do {
      key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    } catch {
      throw TMBClientError.invalidKey
    }
  }

  public var rawRepresentation: Data { key.rawRepresentation }

  public var publicJWK: Org.Nnabeyang.TmbDefs_PublicJwk {
    get throws {
      let representation = key.publicKey.x963Representation
      guard representation.count == 65, representation.first == 4 else {
        throw TMBClientError.invalidKey
      }
      let x = representation[representation.index(after: representation.startIndex) ..< representation.index(representation.startIndex, offsetBy: 33)]
      let y = representation[representation.index(representation.startIndex, offsetBy: 33) ..< representation.endIndex]
      return try Org.Nnabeyang.TmbDefs_PublicJwk.make(
        crv: "P-256",
        kty: "EC",
        x: Data(x).tmbBase64URLEncodedString(),
        y: Data(y).tmbBase64URLEncodedString()
      )
    }
  }

  public func deviceProof(
    deviceID: String,
    audience: TMBOrigin,
    method: String,
    requestURL: URL,
    body: Data,
    nonce: String?,
    now: Date = Date(),
    jti: String = UUID().uuidString
  ) throws -> String {
    try signedJWT(
      header: TMBDeviceProofHeader(
        alg: "ES256",
        typ: "tmb-device+jwt",
        kid: deviceID
      ),
      claims: TMBDeviceProofClaims(
        subject: deviceID,
        audience: audience.url.absoluteString,
        method: method,
        url: requestURL.absoluteString,
        bodyHash: Data(SHA256.hash(data: body)).tmbBase64URLEncodedString(),
        issuedAt: Int(now.timeIntervalSince1970),
        expiresAt: Int(now.timeIntervalSince1970) + 60,
        jti: jti,
        nonce: nonce
      )
    )
  }

  public func dpopProof(
    method: String,
    proofRequest: Org.Nnabeyang.TmbDefs_ProofRequest,
    accessToken: String? = nil,
    now: Date = Date(),
    jti: String = UUID().uuidString
  ) throws -> String {
    guard let endpoint = URL(string: proofRequest.endpoint.rawValue),
      endpoint.scheme?.lowercased() == "https"
    else {
      throw TMBClientError.invalidProofEndpoint
    }
    return try dpopProof(
      method: method,
      endpoint: endpoint,
      nonce: proofRequest.nonce,
      accessToken: accessToken,
      now: now,
      jti: jti
    )
  }

  public func dpopProof(
    method: String,
    endpoint: URL,
    nonce: String?,
    accessToken: String? = nil,
    now: Date = Date(),
    jti: String = UUID().uuidString
  ) throws -> String {
    guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
      throw TMBClientError.invalidProofEndpoint
    }
    return try signedJWT(
      header: TMBDeviceDPoPHeader(
        alg: "ES256",
        typ: "dpop+jwt",
        jwk: try publicJWK
      ),
      claims: TMBDeviceDPoPClaims(
        jti: jti,
        method: method,
        url: endpoint.absoluteString,
        issuedAt: Int(now.timeIntervalSince1970),
        nonce: nonce,
        accessTokenHash: accessToken.map {
          Data(SHA256.hash(data: Data($0.utf8))).tmbBase64URLEncodedString()
        }
      )
    )
  }

  private func signedJWT<Header: Encodable, Claims: Encodable>(
    header: Header,
    claims: Claims
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encodedHeader = try encoder.encode(header).tmbBase64URLEncodedString()
    let encodedClaims = try encoder.encode(claims).tmbBase64URLEncodedString()
    let signingInput = Data("\(encodedHeader).\(encodedClaims)".utf8)
    let signature = try key.signature(for: signingInput).rawRepresentation
    return "\(encodedHeader).\(encodedClaims).\(signature.tmbBase64URLEncodedString())"
  }
}

private struct TMBDeviceProofHeader: Encodable {
  let alg: String
  let typ: String
  let kid: String
}

private struct TMBDeviceProofClaims: Encodable {
  let subject: String
  let audience: String
  let method: String
  let url: String
  let bodyHash: String
  let issuedAt: Int
  let expiresAt: Int
  let jti: String
  let nonce: String?

  enum CodingKeys: String, CodingKey {
    case subject = "sub"
    case audience = "aud"
    case method = "htm"
    case url = "htu"
    case bodyHash = "body_hash"
    case issuedAt = "iat"
    case expiresAt = "exp"
    case jti
    case nonce
  }
}

private struct TMBDeviceDPoPHeader: Encodable {
  let alg: String
  let typ: String
  let jwk: Org.Nnabeyang.TmbDefs_PublicJwk
}

private struct TMBDeviceDPoPClaims: Encodable {
  let jti: String
  let method: String
  let url: String
  let issuedAt: Int
  let nonce: String?
  let accessTokenHash: String?

  enum CodingKeys: String, CodingKey {
    case jti
    case method = "htm"
    case url = "htu"
    case issuedAt = "iat"
    case nonce
    case accessTokenHash = "ath"
  }
}

extension Data {
  fileprivate func tmbBase64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
