import Crypto
import Foundation
import SwiftAtproto
import TangledLexicons
import Testing

@testable import SwiftTangled

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct TMBOriginTests {
  @Test func canonicalizesSimpleHTTPSOrigin() throws {
    #expect(try TMBOrigin("https://TMB.EXAMPLE/").url.absoluteString == "https://tmb.example")
    #expect(try TMBOrigin("https://tmb.example:8443").url.absoluteString == "https://tmb.example:8443")
  }

  @Test(
    arguments: [
      "http://tmb.example",
      "https://user@tmb.example",
      "https://tmb.example/path",
      "https://tmb.example?query=yes",
      "https://tmb.example#fragment",
    ])
  func rejectsInvalidOrigins(value: String) {
    #expect(throws: TMBClientError.invalidOrigin) {
      try TMBOrigin(value)
    }
  }
}

@Suite struct TMBProofKeyTests {
  @Test func deviceProofHasExpectedClaimsAndValidSignature() throws {
    let key = TMBProofKey()
    let origin = try TMBOrigin("https://tmb.example")
    let endpoint = URL(string: "https://tmb.example/xrpc/org.nnabeyang.tmb.revokeDevice")!
    let body = Data("{}".utf8)
    let proof = try key.deviceProof(
      deviceID: "device-1",
      audience: origin,
      method: "POST",
      requestURL: endpoint,
      body: body,
      nonce: "nonce-1",
      now: Date(timeIntervalSince1970: 1_000),
      jti: "jti-1"
    )

    let parts = proof.split(separator: ".").map(String.init)
    #expect(parts.count == 3)
    let header = try jsonObject(parts[0])
    let claims = try jsonObject(parts[1])
    #expect(header["alg"] as? String == "ES256")
    #expect(header["typ"] as? String == "tmb-device+jwt")
    #expect(header["kid"] as? String == "device-1")
    #expect(claims["sub"] as? String == "device-1")
    #expect(claims["aud"] as? String == "https://tmb.example")
    #expect(claims["htm"] as? String == "POST")
    #expect(claims["htu"] as? String == endpoint.absoluteString)
    #expect(claims["nonce"] as? String == "nonce-1")
    #expect(claims["jti"] as? String == "jti-1")
    #expect(claims["iat"] as? Int == 1_000)
    #expect(claims["exp"] as? Int == 1_060)
    #expect(claims["body_hash"] as? String == sha256Base64URL(body))

    let signatureData = try #require(Data(tmbBase64URL: parts[2]))
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
    let publicKey = try verifyingKey(try key.publicJWK)
    #expect(
      publicKey.isValidSignature(
        signature,
        for: Data("\(parts[0]).\(parts[1])".utf8)
      ))
  }

  @Test func dpopProofUsesProofRequestAndAccessTokenHash() throws {
    let key = TMBProofKey()
    let request = try Org.Nnabeyang.TmbDefs_ProofRequest.make(
      endpoint: .init(rawValue: "https://issuer.example/token"),
      nonce: "dpop-nonce"
    )
    let proof = try key.dpopProof(
      method: "POST",
      proofRequest: request,
      accessToken: "access-token",
      now: Date(timeIntervalSince1970: 2_000),
      jti: "dpop-jti"
    )
    let parts = proof.split(separator: ".").map(String.init)
    let header = try jsonObject(parts[0])
    let claims = try jsonObject(parts[1])
    #expect(header["typ"] as? String == "dpop+jwt")
    #expect(header["jwk"] != nil)
    #expect(claims["htu"] as? String == "https://issuer.example/token")
    #expect(claims["nonce"] as? String == "dpop-nonce")
    #expect(claims["ath"] as? String == sha256Base64URL(Data("access-token".utf8)))
  }

  @Test func rawRepresentationRestoresSamePublicKey() throws {
    let first = TMBProofKey()
    let restored = try TMBProofKey(rawRepresentation: first.rawRepresentation)
    #expect(try first.publicJWK == restored.publicJWK)
  }
}

@Suite struct TMBClientTests {
  @Test func reportsEnrolledAndRotatedCredentialsToPersistence() async throws {
    let recorder = TMBRequestRecorder(
      responses: [
        .json(status: 200, body: #"{"deviceId":"device-1","nonce":"nonce-1"}"#),
        .json(status: 200, body: "{}", headers: ["TMB-Device-Nonce": "nonce-2"]),
      ]
    )
    let changes = TMBChangeRecorder()
    let client = TMBClient(
      origin: try TMBOrigin("https://tmb.example"),
      credentialsDidChange: { credentials in
        changes.record(credentials)
      },
      transport: TMBRecordingTransport(recorder: recorder)
    )

    _ = try await client.enroll(name: "device", credential: "credential")
    _ = try await client.response(
      XRPCRequestComponents(
        nsId: "org.nnabeyang.tmb.revokeDevice",
        queryItems: [],
        headers: [:],
        method: .post,
        body: Data("{}".utf8)
      )
    )

    #expect(changes.nonces == ["nonce-1", "nonce-2"])
  }

  @Test func enrollmentUsesOneTimeCredentialAndStoresReturnedDevice() async throws {
    let recorder = TMBRequestRecorder(
      responses: [
        .json(status: 200, body: #"{"deviceId":"device-1","nonce":"nonce-1"}"#)
      ])
    let client = TMBClient(
      origin: try TMBOrigin("https://tmb.example"),
      transport: TMBRecordingTransport(recorder: recorder)
    )
    let credentials = try await client.enroll(
      name: "CI agent",
      credential: "one-time-secret"
    )
    #expect(credentials.deviceID == "device-1")
    #expect(credentials.nonce == "nonce-1")
    #expect(await client.credentials()?.deviceID == "device-1")

    let requests = await recorder.requests
    let request = try #require(requests.first)
    #expect(request.url?.absoluteString == "https://tmb.example/xrpc/org.nnabeyang.tmb.enrollDevice")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "TMB-Enrollment one-time-secret")
    #expect(request.value(forHTTPHeaderField: "TMB-Device-Proof") == nil)
  }

  @Test func useDeviceNonceRetriesOnceWithFreshProof() async throws {
    let recorder = TMBRequestRecorder(
      responses: [
        .json(
          status: 401,
          body: #"{"error":"UseDeviceNonce"}"#,
          headers: ["TMB-Device-Nonce": "nonce-2"]
        ),
        .json(status: 200, body: #"{"revoked":true}"#),
      ])
    let client = TMBClient(
      origin: try TMBOrigin("https://tmb.example"),
      credentials: TMBDeviceCredentials(
        deviceID: "device-1",
        nonce: "nonce-1",
        proofKey: TMBProofKey()
      ),
      transport: TMBRecordingTransport(recorder: recorder)
    )

    let output = try await client.TmbRevokeDevice(
      input: Org.Nnabeyang.TmbRevokeDevice_Input()
    )
    #expect(output.revoked)
    #expect(await client.credentials()?.nonce == "nonce-2")

    let requests = await recorder.requests
    #expect(requests.count == 2)
    let first = try proofClaims(requests[0])
    let second = try proofClaims(requests[1])
    #expect(first["nonce"] as? String == "nonce-1")
    #expect(second["nonce"] as? String == "nonce-2")
    #expect(first["jti"] as? String != second["jti"] as? String)
  }

  @Test func replayIsNotRetried() async throws {
    let recorder = TMBRequestRecorder(
      responses: [.json(status: 409, body: #"{"error":"ReplayDetected"}"#)])
    let client = try protectedClient(recorder: recorder)
    await #expect(throws: TMBClientError.replayDetected) {
      try await client.TmbRevokeDevice(input: Org.Nnabeyang.TmbRevokeDevice_Input())
    }
    #expect(await recorder.requests.count == 1)
  }

  @Test func unavailableResponseUsesSanitizedError() async throws {
    let recorder = TMBRequestRecorder(
      responses: [
        .json(
          status: 503,
          body: #"{"error":"ServiceUnavailable","message":"secret upstream body"}"#)
      ])
    let client = try protectedClient(recorder: recorder)
    await #expect(throws: TMBClientError.serviceUnavailable) {
      try await client.TmbRevokeDevice(input: Org.Nnabeyang.TmbRevokeDevice_Input())
    }
    #expect(TMBClientError.serviceUnavailable.localizedDescription.contains("secret") == false)
  }

  @Test func malformedEnrollmentResponseIsRejected() async throws {
    let recorder = TMBRequestRecorder(responses: [.json(status: 200, body: "not-json")])
    let client = TMBClient(
      origin: try TMBOrigin("https://tmb.example"),
      transport: TMBRecordingTransport(recorder: recorder)
    )
    await #expect(throws: TMBClientError.invalidResponse) {
      try await client.enroll(name: "CI agent", credential: "one-time-secret")
    }
  }

  @Test func invalidEnrollmentMapsToAuthenticationRequired() async throws {
    let recorder = TMBRequestRecorder(
      responses: [.json(status: 401, body: #"{"error":"InvalidEnrollment"}"#)]
    )
    let client = TMBClient(
      origin: try TMBOrigin("https://tmb.example"),
      transport: TMBRecordingTransport(recorder: recorder)
    )
    await #expect(throws: TMBClientError.authenticationRequired) {
      try await client.enroll(name: "CI agent", credential: "expired-secret")
    }
  }

  @Test func protectedRequestRequiresDeviceCredentials() async throws {
    let recorder = TMBRequestRecorder(responses: [])
    let client = TMBClient(
      origin: try TMBOrigin("https://tmb.example"),
      transport: TMBRecordingTransport(recorder: recorder)
    )
    await #expect(throws: TMBClientError.missingDeviceCredentials) {
      try await client.TmbRevokeDevice(input: Org.Nnabeyang.TmbRevokeDevice_Input())
    }
    #expect(await recorder.requests.isEmpty)
  }

  private func protectedClient(recorder: TMBRequestRecorder) throws -> TMBClient {
    TMBClient(
      origin: try TMBOrigin("https://tmb.example"),
      credentials: TMBDeviceCredentials(
        deviceID: "device-1",
        nonce: "nonce-1",
        proofKey: TMBProofKey()
      ),
      transport: TMBRecordingTransport(recorder: recorder)
    )
  }
}

private struct TMBRecordingTransport: HTTPTransport {
  let recorder: TMBRequestRecorder

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await recorder.send(request)
  }
}

private actor TMBRequestRecorder {
  private(set) var requests: [URLRequest] = []
  private var responses: [TMBMockResponse]

  init(responses: [TMBMockResponse]) {
    self.responses = responses
  }

  func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    guard !responses.isEmpty else {
      throw TMBClientError.transport
    }
    let response = responses.removeFirst()
    return (
      response.data,
      HTTPURLResponse(
        url: request.url!,
        statusCode: response.status,
        httpVersion: "HTTP/1.1",
        headerFields: response.headers
      )!
    )
  }
}

private struct TMBMockResponse {
  let status: Int
  let data: Data
  let headers: [String: String]

  static func json(
    status: Int,
    body: String,
    headers: [String: String] = [:]
  ) -> TMBMockResponse {
    TMBMockResponse(status: status, data: Data(body.utf8), headers: headers)
  }
}

private final class TMBChangeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String?] = []

  var nonces: [String?] {
    lock.withLock { values }
  }

  func record(_ credentials: TMBDeviceCredentials) {
    lock.withLock {
      values.append(credentials.nonce)
    }
  }
}

private func proofClaims(_ request: URLRequest) throws -> [String: Any] {
  let proof = try #require(request.value(forHTTPHeaderField: "TMB-Device-Proof"))
  let parts = proof.split(separator: ".").map(String.init)
  return try jsonObject(parts[1])
}

private func jsonObject(_ value: String) throws -> [String: Any] {
  let data = try #require(Data(tmbBase64URL: value))
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func verifyingKey(
  _ jwk: Org.Nnabeyang.TmbDefs_PublicJwk
) throws -> P256.Signing.PublicKey {
  let x = try #require(Data(tmbBase64URL: jwk.x))
  let y = try #require(Data(tmbBase64URL: jwk.y))
  return try P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)
}

private func sha256Base64URL(_ data: Data) -> String {
  Data(SHA256.hash(data: data)).tmbBase64URLEncodedString()
}

extension Data {
  fileprivate init?(tmbBase64URL value: String) {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    self.init(base64Encoded: base64)
  }

  fileprivate func tmbBase64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
