import ArgumentParser
import Foundation
import SwiftTangled

struct AuthStatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show current tng authentication status"
  )

  func run() async throws {
    try await runCLICommand {
      if let rawEndpoint = ProcessInfo.processInfo.environment["TNG_AUTH_AGENT"] {
        guard CLIAccountOverride.identifier == nil else {
          throw ValidationError("--account cannot be combined with TNG_AUTH_AGENT")
        }
        let status = try await AuthAgentClient(
          endpoint: AuthAgentEndpoint(environmentValue: rawEndpoint)
        ).status()
        var lines = [
          "Signed in as @\(status.handle)",
          "DID: \(status.accountDID)",
          "Source: auth-agent",
          "Profile: \(status.profile.rawValue)",
          "Operations: \(status.operations.map(\.rawValue).sorted().joined(separator: ", "))",
        ]
        if let repositoryDID = status.repositoryDID {
          lines.append("Repository DID: \(repositoryDID)")
        }
        if let deadline = status.deadlineUnixMilliseconds {
          lines.append("Deadline: \(deadline)")
        }
        return CLICommandOutput(stdout: lines.joined(separator: "\n") + "\n")
      }
      let configured = try CLISessionStore.make()
      let stored: StoredSession?
      do {
        stored = try configured.store.load()
      } catch let error as TangledError {
        throw CLICommandError.authentication(
          "failed to read stored session: \(describeTangledError(error))"
        )
      }
      guard let session = stored else {
        throw CLICommandError.authenticationRequired(
          "run 'tng auth login <handle>' to sign in"
        )
      }
      var lines = ["Signed in as @\(session.handle)", "DID: \(session.did)"]
      lines.append("Source: \(configured.registry == nil ? "session-file" : "account-registry")")
      if let profile = session.profile {
        lines.append("Profile: \(profile.rawValue)")
      }
      if let expiry = session.archive.tokenState.accessToken.expiry {
        let remaining = Int(expiry.timeIntervalSinceNow)
        if remaining > 0 {
          lines.append("Access token expires in \(remaining)s (at \(expiry.formatted()))")
        } else {
          lines.append("Access token expired \(-remaining)s ago; will refresh on next request")
        }
      }
      return CLICommandOutput(stdout: lines.joined(separator: "\n") + "\n")
    }
  }
}
