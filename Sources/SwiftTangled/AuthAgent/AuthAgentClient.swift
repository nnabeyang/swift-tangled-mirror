import Foundation
import HTTPTypes
import SwiftAtproto
import TangledLexicons

public struct AuthAgentStatus: Codable, Equatable, Sendable {
  public let accountDID: String
  public let handle: String
  public let profile: AuthenticationProfile
  public let repositoryDID: String?
  public let operations: [AuthAgentOperation]
  public let deadlineUnixMilliseconds: Int64?
  public let authorizedScopes: [String]
  public let maximumBodyBytes: UInt64
  public let remainingJobUploadBytes: UInt64
}

public enum AuthAgentEndpoint: Equatable, Sendable {
  case vsock(port: UInt32)
  case unix(path: String)

  public init(environmentValue: String) throws {
    guard let components = URLComponents(string: environmentValue),
      components.scheme == "vsock",
      components.host == "host",
      let port = components.port,
      (1 ... Int(UInt32.max)).contains(port),
      components.path.isEmpty
    else {
      throw AuthAgentError.invalidEndpoint(environmentValue)
    }
    self = .vsock(port: UInt32(port))
  }

  func connect(maximumBodyBytes: UInt64) throws -> AuthAgentSocket {
    switch self {
    case .unix(let path):
      return try AuthAgentSocket.connectUnix(path: path, maximumBodyBytes: maximumBodyBytes)
    case .vsock(let port):
      #if canImport(Darwin)
        return try AuthAgentSocket.connectVSock(port: port, maximumBodyBytes: maximumBodyBytes)
      #else
        throw AuthAgentError.invalidEndpoint("vsock://host:\(port) is unavailable on this platform")
      #endif
    }
  }
}

public struct AuthAgentClient: XRPCCallable, Sendable {
  public let endpoint: AuthAgentEndpoint
  public let maximumBodyBytes: UInt64

  public init(
    endpoint: AuthAgentEndpoint,
    maximumBodyBytes: UInt64 = AuthAgentProtocol.defaultMaximumBodyBytes
  ) {
    self.endpoint = endpoint
    self.maximumBodyBytes = maximumBodyBytes
  }

  public nonisolated func getProxy(nsid _: String) -> String? { nil }

  public func status() async throws -> AuthAgentStatus {
    let response = try await exchange(metadata: .init(kind: .status))
    return try decodeStatus(from: response.metadata)
  }

  public func probe() async throws -> AuthAgentStatus {
    let response = try await exchange(metadata: .init(kind: .probe))
    return try decodeStatus(from: response.metadata)
  }

  public func response(_ components: XRPCRequestComponents) async throws -> Data {
    var headers: [String: String] = [:]
    for field in components.headers {
      let name = field.name.rawName.lowercased()
      guard headers[name] == nil else {
        throw AuthAgentError.protocolViolation("duplicate request header \(name)")
      }
      headers[name] = field.value
    }
    let body = components.body ?? Data()
    var metadata = AuthAgentFrameMetadata(
      kind: .xrpc,
      requestID: UUID().uuidString.lowercased(),
      bodyLength: UInt64(body.count)
    )
    metadata.method = components.method.rawValue
    metadata.nsid = components.nsId
    metadata.query = try components.queryItems.map(authAgentWireQueryItem)
    metadata.headers = headers
    return try await exchange(metadata: metadata, body: body).body
  }

  private func exchange(
    metadata: AuthAgentFrameMetadata,
    body: Data = Data()
  ) async throws -> AuthAgentFrame {
    let endpoint = self.endpoint
    let maximumBodyBytes = self.maximumBodyBytes
    return try await Task.detached {
      let socket = try endpoint.connect(maximumBodyBytes: maximumBodyBytes)
      try socket.send(AuthAgentFrame(metadata: metadata, body: body))
      let response = try socket.receive()
      if response.metadata.kind == .failure {
        throw brokerError(response.metadata)
      }
      guard response.metadata.kind == .response else {
        throw AuthAgentError.protocolViolation("expected response frame")
      }
      return response
    }.value
  }
}

private func decodeStatus(from metadata: AuthAgentFrameMetadata) throws -> AuthAgentStatus {
  guard let did = metadata.accountDID,
    let handle = metadata.handle,
    let profile = metadata.profile,
    let operations = metadata.operations,
    let scopes = metadata.authorizedScopes,
    let maximumBodyBytes = metadata.maxBodyBytes,
    let remaining = metadata.remainingJobUploadBytes
  else {
    throw AuthAgentError.malformedFrame("status fields are missing")
  }
  return AuthAgentStatus(
    accountDID: did,
    handle: handle,
    profile: profile,
    repositoryDID: metadata.repositoryDID,
    operations: operations,
    deadlineUnixMilliseconds: metadata.deadlineUnixMilliseconds,
    authorizedScopes: scopes,
    maximumBodyBytes: maximumBodyBytes,
    remainingJobUploadBytes: remaining
  )
}

func authAgentWireQueryItem(_ item: URLQueryItem) throws -> AuthAgentQueryItem {
  guard let rawValue = item.value else {
    return AuthAgentQueryItem(name: item.name, value: nil)
  }
  guard let value = rawValue.removingPercentEncoding else {
    throw AuthAgentError.protocolViolation("request query contains an invalid value")
  }
  return AuthAgentQueryItem(name: item.name, value: value)
}

private func brokerError(_ metadata: AuthAgentFrameMetadata) -> AuthAgentError {
  switch metadata.errorCode {
  case "policy_denied": .policyDenied(metadata.errorMessage ?? "request is not allowed")
  case "deadline_exceeded": .deadlineExceeded
  case "quota_exceeded": .quotaExceeded
  case "incompatible_version": .incompatibleVersion(metadata.version)
  default: .upstream(metadata.errorMessage ?? "unknown broker failure")
  }
}

extension PDSClient {
  public static func authAgent(
    endpoint: AuthAgentEndpoint
  ) async throws -> PDSClient {
    let client = AuthAgentClient(endpoint: endpoint)
    let status = try await client.status()
    guard status.profile == .ciReporting else {
      throw AuthAgentError.policyDenied("agent does not use the ci-reporting profile")
    }
    return PDSClient(
      client: client,
      repoDID: status.accountDID,
      authorizedScopes: status.authorizedScopes
    )
  }
}
