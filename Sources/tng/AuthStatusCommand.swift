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
      let stored: StoredSession?
      do {
        stored = try CLISessionStore.make().store.load()
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
      var lines = [
        "Signed in as @\(session.handle)",
        "DID: \(session.did)",
      ]
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
