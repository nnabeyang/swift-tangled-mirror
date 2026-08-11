import Foundation

public enum AuthAgentOperation: String, Codable, CaseIterable, Sendable {
  case artifactUpload = "artifact-upload"
  case issueComment = "issue-comment"
  case pullRequestComment = "pull-request-comment"
}

public enum AuthAgentMessageKind: String, Codable, Sendable {
  case probe
  case bind
  case status
  case xrpc
  case response
  case failure
}

public struct AuthAgentQueryItem: Codable, Equatable, Sendable {
  public let name: String
  public let value: String?

  public init(name: String, value: String?) {
    self.name = name
    self.value = value
  }
}

public struct AuthAgentFrameMetadata: Codable, Equatable, Sendable {
  public var version: Int
  public var kind: AuthAgentMessageKind
  public var requestID: String?
  public var bodyLength: UInt64
  public var jobID: String?
  public var repositoryDID: String?
  public var operations: [AuthAgentOperation]?
  public var deadlineUnixMilliseconds: Int64?
  public var method: String?
  public var nsid: String?
  public var query: [AuthAgentQueryItem]?
  public var headers: [String: String]?
  public var statusCode: Int?
  public var errorCode: String?
  public var errorMessage: String?
  public var accountDID: String?
  public var handle: String?
  public var profile: AuthenticationProfile?
  public var authorizedScopes: [String]?
  public var maxBodyBytes: UInt64?
  public var remainingJobUploadBytes: UInt64?

  public init(
    version: Int = AuthAgentProtocol.version,
    kind: AuthAgentMessageKind,
    requestID: String? = nil,
    bodyLength: UInt64 = 0
  ) {
    self.version = version
    self.kind = kind
    self.requestID = requestID
    self.bodyLength = bodyLength
  }
}

public struct AuthAgentFrame: Equatable, Sendable {
  public let metadata: AuthAgentFrameMetadata
  public let body: Data

  public init(metadata: AuthAgentFrameMetadata, body: Data = Data()) {
    self.metadata = metadata
    self.body = body
  }
}

public enum AuthAgentProtocol {
  public static let version = 1
  public static let maximumMetadataBytes = 64 * 1024
  public static let defaultMaximumBodyBytes: UInt64 = 128 * 1024 * 1024
  public static let defaultMaximumJobUploadBytes: UInt64 = 512 * 1024 * 1024
  public static let artifactMaximumBytes: UInt64 = 50 * 1024 * 1024
  public static let defaultVSockPort: UInt32 = 10_241
}

public enum AuthAgentError: Error, Equatable, Sendable {
  case invalidEndpoint(String)
  case invalidSocketPath(String)
  case connectionFailed(Int32)
  case connectionClosed
  case ioFailed(Int32)
  case malformedFrame(String)
  case metadataTooLarge
  case bodyTooLarge(maximumBytes: UInt64, actualBytes: UInt64)
  case incompatibleVersion(Int)
  case protocolViolation(String)
  case policyDenied(String)
  case deadlineExceeded
  case quotaExceeded
  case upstream(String)
}

extension AuthAgentError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint(let value): "invalid TNG_AUTH_AGENT endpoint: \(value)"
    case .invalidSocketPath(let value): "invalid auth-agent socket path: \(value)"
    case .connectionFailed(let code): "auth-agent connection failed (errno \(code))"
    case .connectionClosed: "auth-agent connection closed"
    case .ioFailed(let code): "auth-agent I/O failed (errno \(code))"
    case .malformedFrame(let message): "malformed auth-agent frame: \(message)"
    case .metadataTooLarge: "auth-agent metadata exceeds 64 KiB"
    case .bodyTooLarge(let maximum, let actual):
      "auth-agent body exceeds \(maximum) bytes (actual: \(actual))"
    case .incompatibleVersion(let version): "unsupported auth-agent protocol version \(version)"
    case .protocolViolation(let message): "auth-agent protocol violation: \(message)"
    case .policyDenied(let message): "auth-agent denied request: \(message)"
    case .deadlineExceeded: "auth-agent job deadline has expired"
    case .quotaExceeded: "auth-agent job upload quota exceeded"
    case .upstream(let message): "auth-agent upstream request failed: \(message)"
    }
  }
}

public enum AuthAgentProtocolCodec {
  public static func encode(_ frame: AuthAgentFrame) throws -> Data {
    guard frame.metadata.version == AuthAgentProtocol.version else {
      throw AuthAgentError.incompatibleVersion(frame.metadata.version)
    }
    guard frame.metadata.bodyLength == UInt64(frame.body.count) else {
      throw AuthAgentError.malformedFrame("body length does not match metadata")
    }
    let metadata = try JSONEncoder().encode(frame.metadata)
    guard metadata.count <= AuthAgentProtocol.maximumMetadataBytes else {
      throw AuthAgentError.metadataTooLarge
    }
    var length = UInt32(metadata.count).bigEndian
    var encoded = withUnsafeBytes(of: &length) { Data($0) }
    encoded.append(metadata)
    encoded.append(frame.body)
    return encoded
  }

  public static func decodeMetadata(_ data: Data) throws -> AuthAgentFrameMetadata {
    guard data.count <= AuthAgentProtocol.maximumMetadataBytes else {
      throw AuthAgentError.metadataTooLarge
    }
    let metadata: AuthAgentFrameMetadata
    do {
      metadata = try JSONDecoder().decode(AuthAgentFrameMetadata.self, from: data)
    } catch {
      throw AuthAgentError.malformedFrame("metadata is not valid JSON")
    }
    guard metadata.version == AuthAgentProtocol.version else {
      throw AuthAgentError.incompatibleVersion(metadata.version)
    }
    return metadata
  }
}
