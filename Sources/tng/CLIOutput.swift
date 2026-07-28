import ArgumentParser
import Foundation
import SwiftTangled

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct CLICommandOutput: Equatable, Sendable {
  private let standardOutput: Data
  let stderr: String
  let isPageable: Bool

  var stdout: String {
    String(decoding: standardOutput, as: UTF8.self)
  }

  var stdoutData: Data {
    standardOutput
  }

  init(stdout: String, stderr: String = "", isPageable: Bool = false) {
    self.standardOutput = Data(stdout.utf8)
    self.stderr = stderr
    self.isPageable = isPageable
  }

  init(stdoutData: Data, stderr: String = "", isPageable: Bool = false) {
    self.standardOutput = stdoutData
    self.stderr = stderr
    self.isPageable = isPageable
  }
}

enum CLICommandError: Error, Equatable, Sendable {
  case authentication(String)
  case authenticationRequired(String)
  case git(String)
}

enum CLIExitCode: Int32, Equatable, Sendable {
  case unexpected = 1
  case api = 3
  case authentication = 4
  case git = 5
  case usage = 64

  var argumentParserValue: ExitCode {
    ExitCode(rawValue)
  }
}

struct CLIErrorReport: Equatable, Sendable {
  let exitCode: CLIExitCode
  let diagnostic: String
}

func runCLICommand(
  jsonErrors: Bool = false,
  _ operation: () async throws -> CLICommandOutput
) async throws {
  do {
    let output = try await operation()
    try CLIOutputWriter.live.write(output)
  } catch {
    let report = errorReport(for: error)
    if jsonErrors {
      writeCLIJSONError(jsonErrorReport(for: error))
    } else {
      write(report.diagnostic, to: .standardError)
    }
    throw report.exitCode.argumentParserValue
  }
}

func runCLIStreamingCommand(
  jsonErrors: Bool = false,
  _ operation: @escaping @Sendable () async throws -> Void
) async throws {
  do {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        await waitForCLIInterrupt()
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  } catch is CancellationError {
    return
  } catch {
    let report = errorReport(for: error)
    if jsonErrors {
      writeCLIJSONError(jsonErrorReport(for: error))
    } else {
      write(report.diagnostic, to: .standardError)
    }
    throw report.exitCode.argumentParserValue
  }
}

struct CLIJSONErrorReport: Codable, Equatable, Sendable {
  let category: String
  let code: String
  let message: String
  let exitCode: Int32
}

private struct CLIJSONErrorEnvelope: Encodable {
  let schemaVersion: Int
  let error: CLIJSONErrorReport

  init(error: CLIJSONErrorReport) {
    schemaVersion = 1
    self.error = error
  }
}

func writeCLIJSONError(_ report: CLIJSONErrorReport) {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  guard let data = try? encoder.encode(CLIJSONErrorEnvelope(error: report)) else { return }
  write(data + Data("\n".utf8), to: .standardError)
}

func jsonErrorReport(for error: any Error) -> CLIJSONErrorReport {
  let report = errorReport(for: error)
  return CLIJSONErrorReport(
    category: jsonErrorCategory(for: report.exitCode),
    code: jsonErrorCode(for: error),
    message: report.diagnostic.trimmingCharacters(in: .whitespacesAndNewlines),
    exitCode: report.exitCode.rawValue
  )
}

private func waitForCLIInterrupt() async {
  signal(SIGINT, SIG_IGN)
  let source = CLIInterruptSource(
    DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
  )
  let signals = AsyncStream<Void> { continuation in
    source.value.setEventHandler {
      continuation.yield()
      continuation.finish()
    }
    continuation.onTermination = { _ in source.value.cancel() }
    source.value.resume()
  }
  for await _ in signals {
    return
  }
}

private final class CLIInterruptSource: @unchecked Sendable {
  let value: any DispatchSourceSignal

  init(_ value: any DispatchSourceSignal) {
    self.value = value
  }
}

func exitCode(for error: any Error) -> Int32 {
  errorReport(for: error).exitCode.rawValue
}

func errorReport(for error: any Error) -> CLIErrorReport {
  if let error = error as? CLIPagerError {
    return CLIErrorReport(
      exitCode: .unexpected,
      diagnostic: "Pager error: \(error.description)\n"
    )
  }
  if let error = error as? PipelineWatchFailure {
    return CLIErrorReport(
      exitCode: .unexpected,
      diagnostic: "Pipeline failed: \(error.diagnostic)\n"
    )
  }
  if let error = error as? CLICommandError {
    switch error {
    case .authentication(let message):
      return CLIErrorReport(
        exitCode: .authentication,
        diagnostic: "Authentication error: \(message)\n"
      )
    case .authenticationRequired(let message):
      return CLIErrorReport(
        exitCode: .authentication,
        diagnostic: "Authentication required: \(message)\n"
      )
    case .git(let message):
      return CLIErrorReport(
        exitCode: .git,
        diagnostic: "Git error: \(message)\n"
      )
    }
  }
  if let error = error as? TangledError {
    let category = authenticationError(error) ? "Authentication error" : "API error"
    return CLIErrorReport(
      exitCode: authenticationError(error) ? .authentication : .api,
      diagnostic: "\(category): \(describeTangledError(error))\n"
    )
  }
  if let error = error as? ArtifactError {
    return CLIErrorReport(
      exitCode: .api,
      diagnostic: "Artifact error: \(describeArtifactError(error))\n"
    )
  }
  if let error = error as? any TangledXRPCError {
    let code = error.error ?? "xrpc_error"
    let detail = error.message.map { "\(code): \($0)" } ?? code
    return CLIErrorReport(
      exitCode: .api,
      diagnostic: "API error: \(detail)\n"
    )
  }
  if error is ValidationError {
    return CLIErrorReport(
      exitCode: .usage,
      diagnostic: "Error: \(error)\n"
    )
  }
  return CLIErrorReport(
    exitCode: .unexpected,
    diagnostic: "Unexpected error: \(error)\n"
  )
}

private func jsonErrorCategory(for exitCode: CLIExitCode) -> String {
  switch exitCode {
  case .unexpected: "unexpected"
  case .api: "api"
  case .authentication: "authentication"
  case .git: "git"
  case .usage: "usage"
  }
}

private func jsonErrorCode(for error: any Error) -> String {
  if error is CLIPagerError {
    return "pager_error"
  }
  if error is PipelineWatchFailure {
    return "pipeline_failed"
  }
  if let error = error as? CLICommandError {
    switch error {
    case .authentication: return "authentication"
    case .authenticationRequired: return "authentication_required"
    case .git: return "git_error"
    }
  }
  if let error = error as? TangledError {
    switch error {
    case .oauthTimeout: return "oauth_timeout"
    case .oauthStateMismatch: return "oauth_state_mismatch"
    case .oauthCancelled: return "oauth_cancelled"
    case .portBindFailure: return "port_bind_failure"
    case .browserLaunchFailed: return "browser_launch_failed"
    case .handleNotResolved: return "handle_not_resolved"
    case .network: return "network"
    case .transport: return "transport"
    case .decoding: return "decoding"
    case .invalidRequest: return "invalid_request"
    case .conflict: return "conflict"
    case .unauthorized: return "unauthorized"
    case .forbidden: return "forbidden"
    case .insufficientScope: return "insufficient_scope"
    case .notFound: return "not_found"
    case .rateLimited: return "rate_limited"
    case .upstreamFailed: return "upstream_failed"
    case .serviceUnavailable: return "service_unavailable"
    case .serverStatus: return "server_status"
    case .notImplemented: return "not_implemented"
    case .keychainFailure: return "keychain_failure"
    case .sessionStoreFailure: return "session_store_failure"
    }
  }
  if let error = error as? ArtifactError {
    switch error {
    case .invalidName: return "invalid_artifact_name"
    case .fileTooLarge: return "artifact_file_too_large"
    case .tagNotAnnotated: return "tag_not_annotated"
    case .alreadyExists: return "artifact_already_exists"
    case .notOwned: return "artifact_not_owned"
    case .invalidBlobCID: return "invalid_blob_cid"
    case .checksumMismatch: return "artifact_checksum_mismatch"
    case .unsafeDestination: return "unsafe_artifact_destination"
    }
  }
  if let error = error as? any TangledXRPCError {
    return error.error ?? "xrpc_error"
  }
  if error is ValidationError {
    return "invalid_usage"
  }
  return "unexpected"
}

private func authenticationError(_ error: TangledError) -> Bool {
  switch error {
  case .unauthorized, .insufficientScope, .oauthTimeout, .oauthStateMismatch, .oauthCancelled,
    .portBindFailure, .browserLaunchFailed, .keychainFailure, .sessionStoreFailure:
    true
  case .forbidden, .notImplemented, .network, .transport, .decoding, .invalidRequest, .conflict,
    .notFound, .rateLimited, .upstreamFailed, .serviceUnavailable,
    .serverStatus, .handleNotResolved:
    false
  }
}

private func write(_ string: String, to fileHandle: FileHandle) {
  guard !string.isEmpty else { return }
  write(Data(string.utf8), to: fileHandle)
}

private func write(_ data: Data, to fileHandle: FileHandle) {
  guard !data.isEmpty else { return }
  fileHandle.write(data)
}

func describeTangledError(_ error: TangledError) -> String {
  switch error {
  case .oauthTimeout:
    "callback timed out"
  case .oauthStateMismatch:
    "state mismatch"
  case .oauthCancelled(let reason):
    "authorization cancelled: \(reason)"
  case .portBindFailure(let reason):
    "failed to bind loopback port: \(reason)"
  case .browserLaunchFailed(let reason):
    "failed to launch browser: \(reason)"
  case .handleNotResolved(let handle):
    "handle could not be resolved: \(handle)"
  case .network(let urlError):
    "network error: \(urlError.localizedDescription)"
  case .transport(let message):
    "transport error: \(message)"
  case .decoding:
    "response decoding failed"
  case .invalidRequest(let message):
    "invalid request\(message.map { ": \($0)" } ?? "")"
  case .conflict(let message):
    "conflict: \(message ?? "record changed since it was read; fetch the latest state and retry")"
  case .unauthorized:
    "unauthorized; run 'tng auth login <handle>'"
  case .forbidden(let message):
    "forbidden\(message.map { ": \($0)" } ?? "")"
  case .insufficientScope(let scope):
    "missing OAuth scope: \(scope); run 'tng auth login <handle>' again"
  case .notFound(let message):
    "not found\(message.map { ": \($0)" } ?? "")"
  case .rateLimited(let retryAfter, let message):
    "rate limited\(retryAfter.map { " (retry after \(Int($0)) seconds)" } ?? "")\(message.map { ": \($0)" } ?? "")"
  case .upstreamFailed(let message):
    "upstream failed\(message.map { ": \($0)" } ?? "")"
  case .serviceUnavailable(let message):
    "service unavailable\(message.map { ": \($0)" } ?? "")"
  case .serverStatus(let code, let message):
    "server returned HTTP \(code)\(message.map { ": \($0)" } ?? "")"
  case .notImplemented(let feature):
    "not implemented: \(feature)"
  case .keychainFailure(let status):
    "keychain error: OSStatus \(status)"
  case .sessionStoreFailure(let message):
    "session store error: \(message)"
  }
}

func describeArtifactError(_ error: ArtifactError) -> String {
  switch error {
  case .invalidName(let name):
    "invalid artifact name: \(name)"
  case .fileTooLarge(let maximumBytes, let actualBytes):
    "file exceeds \(maximumBytes) bytes"
      + (actualBytes.map { " (actual: \($0) bytes)" } ?? "")
  case .tagNotAnnotated(let tag):
    "remote tag is not annotated: \(tag)"
  case .alreadyExists(let uri):
    "artifact already exists: \(uri); pass --force to replace your own record"
  case .notOwned(let uri):
    "artifact is not owned by the signed-in account: \(uri)"
  case .invalidBlobCID(let cid):
    "blob CID does not contain a supported SHA-256 digest: \(cid)"
  case .checksumMismatch(let expectedCID, let actualDigest):
    "download checksum mismatch for \(expectedCID) (actual digest: \(actualDigest))"
  case .unsafeDestination(let path):
    "unsafe download destination: \(path)"
  }
}

struct StderrOutput: TextOutputStream {
  mutating func write(_ string: String) {
    FileHandle.standardError.write(Data(string.utf8))
  }
}
