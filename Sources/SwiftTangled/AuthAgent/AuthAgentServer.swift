import Foundation
import HTTPTypes
import OAuth4Swift
import SwiftAtproto
import TangledLexicons

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct AuthAgentServerConfiguration: Sendable {
  public let socketPath: String
  public let profile: AuthenticationProfile
  public let maximumBodyBytes: UInt64
  public let maximumJobUploadBytes: UInt64

  public init(
    socketPath: String,
    profile: AuthenticationProfile,
    maximumBodyBytes: UInt64 = AuthAgentProtocol.defaultMaximumBodyBytes,
    maximumJobUploadBytes: UInt64 = AuthAgentProtocol.defaultMaximumJobUploadBytes
  ) {
    self.socketPath = socketPath
    self.profile = profile
    self.maximumBodyBytes = maximumBodyBytes
    self.maximumJobUploadBytes = maximumJobUploadBytes
  }
}

public struct AuthAgentAuthentication: Sendable {
  public let accountDID: String
  public let handle: String
  public let profile: AuthenticationProfile
  public let authorizedScopes: [String]
  public let client: any XRPCCallable

  public init(
    accountDID: String,
    handle: String,
    profile: AuthenticationProfile,
    authorizedScopes: [String],
    client: any XRPCCallable
  ) {
    self.accountDID = accountDID
    self.handle = handle
    self.profile = profile
    self.authorizedScopes = authorizedScopes
    self.client = client
  }
}

public struct AuthAgentServer: Sendable {
  private let configuration: AuthAgentServerConfiguration
  private let authentication: AuthAgentAuthentication
  private let brokerState: AuthAgentBrokerState
  private let recordClient: PDSRecordClient

  public init(
    configuration: AuthAgentServerConfiguration,
    sessionStore: any SessionStore,
    recordClient: PDSRecordClient = PDSRecordClient()
  ) throws {
    guard configuration.profile == .ciReporting else {
      throw AuthAgentError.policyDenied("unsupported authentication profile")
    }
    guard configuration.maximumBodyBytes > 0,
      configuration.maximumJobUploadBytes > 0
    else {
      throw AuthAgentError.protocolViolation("body and job upload limits must be positive")
    }
    guard let stored = try sessionStore.load() else { throw TangledError.unauthorized }
    guard stored.profile == configuration.profile else {
      throw AuthAgentError.policyDenied(
        "stored session profile does not match \(configuration.profile.rawValue)"
      )
    }
    let agent = try AtprotoOAuthAgent(
      archive: .init(did: stored.did, session: stored.archive),
      clientId: stored.resolvedClientID,
      authFetcher: URLSession.manualRedirect(),
      atprotoResolver: URLSessionATPResolver(),
      delegate: sessionStore
    )
    try self.init(
      configuration: configuration,
      authentication: AuthAgentAuthentication(
        accountDID: stored.did,
        handle: stored.handle,
        profile: stored.profile ?? .ciReporting,
        authorizedScopes: stored.archive.tokenState.authorizedScopes,
        client: agent
      ),
      recordClient: recordClient
    )
  }

  public init(
    configuration: AuthAgentServerConfiguration,
    authentication: AuthAgentAuthentication,
    recordClient: PDSRecordClient = PDSRecordClient()
  ) throws {
    guard configuration.profile == .ciReporting,
      authentication.profile == configuration.profile
    else { throw AuthAgentError.policyDenied("unsupported authentication profile") }
    guard authentication.accountDID.hasPrefix("did:"),
      !authentication.handle.isEmpty,
      !authentication.authorizedScopes.isEmpty
    else { throw AuthAgentError.protocolViolation("authentication identity is incomplete") }
    guard configuration.maximumBodyBytes > 0, configuration.maximumJobUploadBytes > 0 else {
      throw AuthAgentError.protocolViolation("body and job upload limits must be positive")
    }
    self.configuration = configuration
    self.authentication = authentication
    self.brokerState = AuthAgentBrokerState(maximumJobUploadBytes: configuration.maximumJobUploadBytes)
    self.recordClient = recordClient
  }

  public func serve() async throws {
    try prepareSocketPath(configuration.socketPath)
    let listener = try makeUnixListener(path: configuration.socketPath)
    guard chmod(configuration.socketPath, mode_t(0o600)) == 0 else {
      authAgentClose(listener)
      try? FileManager.default.removeItem(atPath: configuration.socketPath)
      throw AuthAgentError.ioFailed(errno)
    }
    setNonblocking(listener)
    defer {
      authAgentClose(listener)
      try? FileManager.default.removeItem(atPath: configuration.socketPath)
    }

    while !Task.isCancelled {
      let accepted = authAgentAccept(listener)
      if accepted >= 0 {
        setBlocking(accepted)
        let connection = AuthAgentSocket(
          fileDescriptor: accepted,
          maximumBodyBytes: configuration.maximumBodyBytes
        )
        Task { await handle(connection) }
      } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
        throw AuthAgentError.ioFailed(errno)
      }
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  private func handle(_ socket: AuthAgentSocket) async {
    var binding: AuthAgentBinding?
    var requestIDs = Set<String>()
    var currentRequestID: String?
    while !Task.isCancelled {
      do {
        let frame = try await Task.detached { try socket.receive() }.value
        currentRequestID = frame.metadata.requestID
        if let requestID = frame.metadata.requestID {
          guard requestIDs.insert(requestID).inserted else {
            throw AuthAgentError.protocolViolation("duplicate request ID")
          }
        }
        let result = try await process(frame, binding: binding)
        binding = result.binding
        try await Task.detached { try socket.send(result.response) }.value
        if frame.metadata.kind == .probe { return }
      } catch AuthAgentError.connectionClosed {
        return
      } catch {
        let failure = failureFrame(error, requestID: currentRequestID)
        try? await Task.detached { try socket.send(failure) }.value
        return
      }
    }
  }

  private func process(
    _ frame: AuthAgentFrame,
    binding: AuthAgentBinding?
  ) async throws -> (response: AuthAgentFrame, binding: AuthAgentBinding?) {
    switch frame.metadata.kind {
    case .probe:
      guard binding == nil, frame.body.isEmpty else {
        throw AuthAgentError.protocolViolation("probe must be the first empty frame")
      }
      return (await statusFrame(binding: nil, requestID: frame.metadata.requestID), nil)
    case .bind:
      guard binding == nil, frame.body.isEmpty else {
        throw AuthAgentError.protocolViolation("connection is already bound")
      }
      let binding = try makeBinding(frame.metadata)
      return (await statusFrame(binding: binding, requestID: frame.metadata.requestID), binding)
    case .status:
      guard let binding else {
        throw AuthAgentError.policyDenied("connection has not been bound by the trusted host")
      }
      try validateDeadline(binding)
      return (await statusFrame(binding: binding, requestID: frame.metadata.requestID), binding)
    case .xrpc:
      guard let binding else {
        throw AuthAgentError.policyDenied("connection has not been bound by the trusted host")
      }
      try validateDeadline(binding)
      let components = try await validateXRPC(frame, binding: binding)
      let body: Data
      do {
        body = try await authentication.client.response(components)
      } catch {
        throw AuthAgentError.upstream("request failed")
      }
      guard UInt64(body.count) <= configuration.maximumBodyBytes else {
        throw AuthAgentError.bodyTooLarge(
          maximumBytes: configuration.maximumBodyBytes,
          actualBytes: UInt64(body.count)
        )
      }
      var metadata = AuthAgentFrameMetadata(
        kind: .response,
        requestID: frame.metadata.requestID,
        bodyLength: UInt64(body.count)
      )
      metadata.statusCode = 200
      return (AuthAgentFrame(metadata: metadata, body: body), binding)
    case .response, .failure:
      throw AuthAgentError.protocolViolation("client sent a response frame")
    }
  }

  private func makeBinding(_ metadata: AuthAgentFrameMetadata) throws -> AuthAgentBinding {
    guard let jobID = metadata.jobID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !jobID.isEmpty,
      let repositoryDID = metadata.repositoryDID,
      repositoryDID.hasPrefix("did:"),
      let operations = metadata.operations,
      !operations.isEmpty,
      let deadline = metadata.deadlineUnixMilliseconds
    else {
      throw AuthAgentError.malformedFrame("bind fields are missing")
    }
    guard Set(operations).count == operations.count else {
      throw AuthAgentError.protocolViolation("bind contains duplicate operations")
    }
    let binding = AuthAgentBinding(
      jobID: jobID,
      repositoryDID: repositoryDID,
      operations: Set(operations),
      deadlineUnixMilliseconds: deadline
    )
    try validateDeadline(binding)
    return binding
  }

  private func validateDeadline(_ binding: AuthAgentBinding) throws {
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    guard now <= binding.deadlineUnixMilliseconds else {
      throw AuthAgentError.deadlineExceeded
    }
  }

  private func validateXRPC(
    _ frame: AuthAgentFrame,
    binding: AuthAgentBinding
  ) async throws -> XRPCRequestComponents {
    guard let nsid = frame.metadata.nsid,
      let rawMethod = frame.metadata.method,
      rawMethod == "GET" || rawMethod == "POST"
    else {
      throw AuthAgentError.malformedFrame("XRPC method or NSID is missing")
    }
    let headers = try safeHeaders(frame.metadata.headers ?? [:])
    switch nsid {
    case "com.atproto.repo.uploadBlob":
      guard rawMethod == "POST", binding.operations.contains(.artifactUpload) else {
        throw AuthAgentError.policyDenied("blob upload is not allowed")
      }
      guard UInt64(frame.body.count) <= AuthAgentProtocol.artifactMaximumBytes else {
        throw AuthAgentError.bodyTooLarge(
          maximumBytes: AuthAgentProtocol.artifactMaximumBytes,
          actualBytes: UInt64(frame.body.count)
        )
      }
      try await brokerState.reserveUpload(bytes: UInt64(frame.body.count), binding: binding)
    case "com.atproto.repo.getRecord", "com.atproto.repo.listRecords":
      guard rawMethod == "GET", binding.operations.contains(.artifactUpload) else {
        throw AuthAgentError.policyDenied("record read is not allowed")
      }
      try validateRecordRead(frame.metadata.query ?? [])
    case "com.atproto.repo.putRecord":
      guard rawMethod == "POST" else {
        throw AuthAgentError.policyDenied("putRecord requires POST")
      }
      try await validatePutRecord(frame.body, binding: binding)
    default:
      throw AuthAgentError.policyDenied("XRPC \(nsid) is not allowed")
    }
    return XRPCRequestComponents(
      nsId: nsid,
      queryItems: (frame.metadata.query ?? []).map { URLQueryItem(name: $0.name, value: $0.value) },
      headers: headers,
      method: HTTPRequest.Method(rawValue: rawMethod)!,
      body: frame.body.isEmpty ? nil : frame.body
    )
  }

  private func validateRecordRead(_ query: [AuthAgentQueryItem]) throws {
    let values = try authAgentQueryValues(query)
    guard values["repo"] == authentication.accountDID,
      values["collection"] == Sh.Tangled.RepoArtifact.nsId
    else {
      throw AuthAgentError.policyDenied("record read must target the bot artifact collection")
    }
  }

  private func validatePutRecord(_ body: Data, binding: AuthAgentBinding) async throws {
    let object: [String: Any]
    do {
      object = try (JSONSerialization.jsonObject(with: body) as? [String: Any]).unwrap()
    } catch {
      throw AuthAgentError.malformedFrame("putRecord body is not a JSON object")
    }
    guard object["repo"] as? String == authentication.accountDID,
      let collection = object["collection"] as? String,
      let record = object["record"] as? [String: Any]
    else {
      throw AuthAgentError.policyDenied("putRecord owner must be the authenticated bot DID")
    }
    switch collection {
    case Sh.Tangled.RepoArtifact.nsId:
      guard binding.operations.contains(.artifactUpload),
        record["repoDid"] as? String == binding.repositoryDID,
        let artifact = record["artifact"] as? [String: Any],
        let size = artifact["size"] as? NSNumber,
        size.uint64Value <= AuthAgentProtocol.artifactMaximumBytes
      else {
        throw AuthAgentError.policyDenied("artifact does not match the bound repository")
      }
    case Sh.Tangled.FeedComment.nsId:
      guard let subject = record["subject"] as? [String: Any],
        let uri = subject["uri"] as? String
      else {
        throw AuthAgentError.malformedFrame("comment subject is missing")
      }
      if uri.contains("/\(Sh.Tangled.RepoIssue.nsId)/") {
        guard binding.operations.contains(.issueComment) else {
          throw AuthAgentError.policyDenied("issue comment is not allowed")
        }
        let issue = try await recordClient.issue(uri: uri)
        guard issue.value.repositoryDID == binding.repositoryDID else {
          throw AuthAgentError.policyDenied("issue belongs to a different repository")
        }
      } else if uri.contains("/\(Sh.Tangled.RepoPull.nsId)/") {
        guard binding.operations.contains(.pullRequestComment) else {
          throw AuthAgentError.policyDenied("pull request comment is not allowed")
        }
        let pull = try await recordClient.pullRequest(uri: uri)
        guard pull.value.target.repositoryDID == binding.repositoryDID else {
          throw AuthAgentError.policyDenied("pull request belongs to a different repository")
        }
      } else {
        throw AuthAgentError.policyDenied("comment subject collection is not allowed")
      }
    default:
      throw AuthAgentError.policyDenied("record collection \(collection) is not allowed")
    }
  }

  private func safeHeaders(_ raw: [String: String]) throws -> HTTPFields {
    var result = HTTPFields()
    for (name, value) in raw {
      let lowercased = name.lowercased()
      guard lowercased == "accept" || lowercased == "content-type",
        let fieldName = HTTPField.Name(name)
      else {
        throw AuthAgentError.policyDenied("request header \(name) is not allowed")
      }
      result[fieldName] = value
    }
    return result
  }

  private func statusFrame(binding: AuthAgentBinding?, requestID: String?) async -> AuthAgentFrame {
    var metadata = AuthAgentFrameMetadata(kind: .response, requestID: requestID)
    metadata.statusCode = 200
    metadata.accountDID = authentication.accountDID
    metadata.handle = authentication.handle
    metadata.profile = authentication.profile
    metadata.repositoryDID = binding?.repositoryDID
    metadata.operations =
      binding.map { Array($0.operations).sorted { $0.rawValue < $1.rawValue } }
      ?? AuthAgentOperation.allCases
    metadata.deadlineUnixMilliseconds = binding?.deadlineUnixMilliseconds
    metadata.authorizedScopes = authentication.authorizedScopes.sorted()
    metadata.maxBodyBytes = configuration.maximumBodyBytes
    metadata.remainingJobUploadBytes = await brokerState.remainingUploadBytes(
      jobID: binding?.jobID
    )
    return AuthAgentFrame(metadata: metadata)
  }
}

func authAgentQueryValues(_ query: [AuthAgentQueryItem]) throws -> [String: String] {
  var values: [String: String] = [:]
  for item in query {
    guard values[item.name] == nil else {
      throw AuthAgentError.policyDenied("request query contains duplicate fields")
    }
    guard let rawValue = item.value,
      let value = rawValue.removingPercentEncoding
    else {
      throw AuthAgentError.policyDenied("request query contains an invalid value")
    }
    values[item.name] = value
  }
  return values
}

private struct AuthAgentBinding: Sendable {
  let jobID: String
  let repositoryDID: String
  let operations: Set<AuthAgentOperation>
  let deadlineUnixMilliseconds: Int64
}

private actor AuthAgentBrokerState {
  private let maximumJobUploadBytes: UInt64
  private var usedUploadBytes: [String: UInt64] = [:]

  init(maximumJobUploadBytes: UInt64) {
    self.maximumJobUploadBytes = maximumJobUploadBytes
  }

  func reserveUpload(bytes: UInt64, binding: AuthAgentBinding) throws {
    let used = usedUploadBytes[binding.jobID, default: 0]
    guard bytes <= maximumJobUploadBytes - min(used, maximumJobUploadBytes) else {
      throw AuthAgentError.quotaExceeded
    }
    usedUploadBytes[binding.jobID] = used + bytes
  }

  func remainingUploadBytes(jobID: String?) -> UInt64 {
    guard let jobID else { return maximumJobUploadBytes }
    return maximumJobUploadBytes - min(usedUploadBytes[jobID, default: 0], maximumJobUploadBytes)
  }
}

private func failureFrame(_ error: Error, requestID: String?) -> AuthAgentFrame {
  var metadata = AuthAgentFrameMetadata(kind: .failure, requestID: requestID)
  metadata.statusCode = 403
  switch error {
  case AuthAgentError.deadlineExceeded:
    metadata.errorCode = "deadline_exceeded"
    metadata.errorMessage = "job deadline has expired"
  case AuthAgentError.quotaExceeded:
    metadata.errorCode = "quota_exceeded"
    metadata.errorMessage = "job upload quota exceeded"
  case AuthAgentError.incompatibleVersion:
    metadata.errorCode = "incompatible_version"
    metadata.errorMessage = "protocol version is not supported"
  case AuthAgentError.policyDenied(let message):
    metadata.errorCode = "policy_denied"
    metadata.errorMessage = message
  default:
    metadata.errorCode = "broker_failure"
    metadata.errorMessage = "auth-agent request failed"
  }
  return AuthAgentFrame(metadata: metadata)
}

private func prepareSocketPath(_ path: String) throws {
  guard path.hasPrefix("/") else { throw AuthAgentError.invalidSocketPath(path) }
  let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
  var parentStat = stat()
  guard lstat(parent, &parentStat) == 0,
    (parentStat.st_mode & S_IFMT) == S_IFDIR,
    parentStat.st_uid == getuid(),
    (parentStat.st_mode & 0o077) == 0
  else {
    throw AuthAgentError.invalidSocketPath("parent directory must be owned mode 0700")
  }
  var socketStat = stat()
  if lstat(path, &socketStat) == 0 {
    guard (socketStat.st_mode & S_IFMT) == S_IFSOCK,
      socketStat.st_uid == getuid(),
      socketStat.st_nlink == 1
    else {
      throw AuthAgentError.invalidSocketPath("existing path is not an owned socket")
    }
    do {
      _ = try AuthAgentSocket.connectUnix(
        path: path,
        maximumBodyBytes: AuthAgentProtocol.defaultMaximumBodyBytes
      )
      throw AuthAgentError.invalidSocketPath("another auth-agent is already listening")
    } catch AuthAgentError.connectionFailed(let code) where code == ECONNREFUSED {
      guard unlink(path) == 0 else { throw AuthAgentError.ioFailed(errno) }
    }
  } else if errno != ENOENT {
    throw AuthAgentError.ioFailed(errno)
  }
}

private func setNonblocking(_ descriptor: Int32) {
  let flags = fcntl(descriptor, F_GETFL, 0)
  if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
}

private func setBlocking(_ descriptor: Int32) {
  let flags = fcntl(descriptor, F_GETFL, 0)
  if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }
}

private extension Optional {
  func unwrap() throws -> Wrapped {
    guard let self else { throw AuthAgentError.malformedFrame("expected value is missing") }
    return self
  }
}
