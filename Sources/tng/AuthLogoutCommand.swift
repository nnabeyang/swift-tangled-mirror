import ArgumentParser
import Foundation
import SwiftTangled

struct AuthLogoutCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "logout",
    abstract: "Revoke and clear the current tng authentication"
  )

  func run() async throws {
    try await runCLICommand {
      let store = try CLISessionStore.make().store
      let session: StoredSession?
      do {
        session = try store.load()
      } catch let error as TangledError {
        try? store.clear()
        throw CLICommandError.authentication(
          "failed to read stored session: \(describeTangledError(error))"
        )
      }
      guard let session else {
        return CLICommandOutput(
          stdout: "",
          stderr: "Not signed in; nothing to log out.\n"
        )
      }
      var diagnostic = ""
      do {
        try await TokenRevoker(session: session).revoke()
      } catch {
        diagnostic += "warning: token revoke failed (\(error)); clearing local session anyway.\n"
      }
      do {
        try store.clear()
      } catch let error as TangledError {
        if !diagnostic.isEmpty {
          writeHumanDiagnostic(diagnostic)
        }
        throw CLICommandError.authentication(
          "failed to clear stored session: \(describeTangledError(error))"
        )
      }
      return CLICommandOutput(
        stdout: "Signed out @\(session.handle) (did: \(session.did)).\n",
        stderr: diagnostic
      )
    }
  }
}
