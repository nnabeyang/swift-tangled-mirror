import Foundation
import SwiftAtproto
import TangledLexicons

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum TMBClientError: Error, Equatable, Sendable {
  case invalidOrigin
  case invalidKey
  case invalidProofEndpoint
  case missingDeviceCredentials
  case authenticationRequired
  case replayDetected
  case serviceUnavailable
  case invalidResponse
  case transport
}

extension TMBClientError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidOrigin: "TMB origin must be a simple HTTPS origin"
    case .invalidKey: "TMB proof key is invalid"
    case .invalidProofEndpoint: "TMB proof endpoint is invalid"
    case .missingDeviceCredentials: "TMB device credentials are unavailable"
    case .authenticationRequired: "TMB device authentication is required"
    case .replayDetected: "TMB rejected a replayed proof"
    case .serviceUnavailable: "TMB is unavailable"
    case .invalidResponse: "TMB returned an invalid response"
    case .transport: "TMB request failed"
    }
  }
}

public struct TMBDeviceCredentials: Sendable {
  public let deviceID: String
  public var nonce: String?
  public let proofKey: TMBProofKey

  public init(deviceID: String, nonce: String?, proofKey: TMBProofKey) {
    self.deviceID = deviceID
    self.nonce = nonce
    self.proofKey = proofKey
  }
}

public actor TMBClient: XRPCCallable {
  public let origin: TMBOrigin
  private let transport: any HTTPTransport
  private let credentialsDidChange: @Sendable (TMBDeviceCredentials) throws -> Void
  private var deviceCredentials: TMBDeviceCredentials?

  public init(
    origin: TMBOrigin,
    credentials: TMBDeviceCredentials? = nil,
    credentialsDidChange: @escaping @Sendable (TMBDeviceCredentials) throws -> Void = { _ in },
    transport: any HTTPTransport = URLSessionTransport()
  ) {
    self.origin = origin
    deviceCredentials = credentials
    self.credentialsDidChange = credentialsDidChange
    self.transport = transport
  }

  public nonisolated func getProxy(nsid _: String) -> String? { nil }

  public func credentials() -> TMBDeviceCredentials? {
    deviceCredentials
  }

  public func setCredentials(_ credentials: TMBDeviceCredentials?) {
    deviceCredentials = credentials
  }

  public func enroll(
    name: String,
    credential: String,
    proofKey: TMBProofKey = TMBProofKey()
  ) async throws -> TMBDeviceCredentials {
    guard !credential.isEmpty else {
      throw TMBClientError.authenticationRequired
    }
    let input = try Org.Nnabeyang.TmbEnrollDevice_Input.make(
      name: name,
      publicKey: try proofKey.publicJWK
    )
    let body = try JSONEncoder().encode(input)
    let endpoint = endpoint(nsid: Org.Nnabeyang.TmbEnrollDevice.id)
    var request = URLRequest(url: endpoint, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("TMB-Enrollment \(credential)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await send(request)
    guard (200 ... 299).contains(response.statusCode) else {
      throw mapFailure(data: data, response: response)
    }
    let output: Org.Nnabeyang.TmbEnrollDevice_Output
    do {
      output = try JSONDecoder().decode(Org.Nnabeyang.TmbEnrollDevice_Output.self, from: data)
    } catch {
      throw TMBClientError.invalidResponse
    }
    let credentials = TMBDeviceCredentials(
      deviceID: output.deviceId,
      nonce: output.nonce,
      proofKey: proofKey
    )
    deviceCredentials = credentials
    try credentialsDidChange(credentials)
    return credentials
  }

  public func revokeDevice() async throws -> Bool {
    let output = try await TmbRevokeDevice(input: .init())
    return output.revoked
  }

  public func response(_ components: XRPCRequestComponents) async throws -> Data {
    guard components.nsId != Org.Nnabeyang.TmbEnrollDevice.id else {
      throw TMBClientError.authenticationRequired
    }
    for attempt in 0 ... 1 {
      guard let credentials = deviceCredentials else {
        throw TMBClientError.missingDeviceCredentials
      }
      let request = try protectedRequest(components, credentials: credentials)
      let (data, response) = try await send(request)
      let responseNonce = response.value(forHTTPHeaderField: "TMB-Device-Nonce")
        .flatMap { $0.isEmpty ? nil : $0 }
      if let responseNonce {
        deviceCredentials?.nonce = responseNonce
        if let updatedCredentials = deviceCredentials {
          try credentialsDidChange(updatedCredentials)
        }
      }
      guard !(200 ... 299).contains(response.statusCode) else {
        return data
      }
      let failure = try? JSONDecoder().decode(TMBFailureEnvelope.self, from: data)
      if failure?.error == "UseDeviceNonce", attempt == 0, responseNonce != nil {
        continue
      }
      throw mapFailure(data: data, response: response)
    }
    throw TMBClientError.invalidResponse
  }

  private func protectedRequest(
    _ components: XRPCRequestComponents,
    credentials: TMBDeviceCredentials
  ) throws -> URLRequest {
    let endpoint = endpoint(nsid: components.nsId)
    guard var urlComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw TMBClientError.invalidResponse
    }
    if !components.queryItems.isEmpty {
      urlComponents.percentEncodedQueryItems = components.queryItems
    }
    guard let url = urlComponents.url else {
      throw TMBClientError.invalidResponse
    }
    let body = components.body ?? Data()
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = components.method.rawValue
    request.httpBody = components.body
    for field in components.headers {
      let name = field.name.rawName.lowercased()
      guard name != "authorization", name != "tmb-device-proof" else {
        throw TMBClientError.invalidResponse
      }
      request.addValue(field.value, forHTTPHeaderField: field.name.rawName)
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(
      try credentials.proofKey.deviceProof(
        deviceID: credentials.deviceID,
        audience: origin,
        method: components.method.rawValue,
        requestURL: url,
        body: body,
        nonce: credentials.nonce
      ),
      forHTTPHeaderField: "TMB-Device-Proof"
    )
    return request
  }

  private func endpoint(nsid: String) -> URL {
    origin.url
      .appendingPathComponent("xrpc", isDirectory: true)
      .appendingPathComponent(nsid, isDirectory: false)
  }

  private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
      return try await transport.send(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TMBClientError {
      throw error
    } catch {
      throw TMBClientError.transport
    }
  }

  private func mapFailure(data: Data, response: HTTPURLResponse) -> any Error {
    let failure = try? JSONDecoder().decode(TMBFailureEnvelope.self, from: data)
    switch failure?.error {
    case "AuthenticationRequired", "InvalidEnrollment":
      return TMBClientError.authenticationRequired
    case "ReplayDetected": return TMBClientError.replayDetected
    default: break
    }
    if response.statusCode == 502 || response.statusCode == 503 || response.statusCode == 504 {
      return TMBClientError.serviceUnavailable
    }
    if let code = failure?.error, !code.isEmpty {
      return UnExpectedError(error: code, message: nil)
    }
    return TMBClientError.invalidResponse
  }
}

private struct TMBFailureEnvelope: Decodable {
  let error: String?
}
