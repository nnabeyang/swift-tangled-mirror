import ArgumentParser
import Foundation
import SwiftTangled

struct AuthLogoutCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "logout",
    abstract: "Revoke and clear stored tng authentication"
  )

  @Flag(help: "Log out every stored account")
  var all = false

  @Flag(help: "Output logged-out accounts as JSON")
  var json = false

  mutating func validate() throws {
    if all, CLIAccountOverride.identifier != nil {
      throw ValidationError("--all cannot be combined with --account")
    }
    if all, ProcessInfo.processInfo.environment["TNG_SESSION_FILE"] != nil {
      throw ValidationError("--all cannot be combined with TNG_SESSION_FILE")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      guard ProcessInfo.processInfo.environment["TNG_AUTH_AGENT"] == nil else {
        throw CLICommandError.authentication(
          "auth logout is unavailable while TNG_AUTH_AGENT is set")
      }
      let configured = try CLISessionStore.make()
      guard let registry = configured.registry else {
        return try await logoutExplicitStore(configured)
      }

      let targets: [AccountSession]
      do {
        if all {
          targets = try registry.accounts()
        } else if let account = configured.account {
          targets = [account]
        } else {
          targets = []
        }
      } catch let error as AccountSessionRegistryError {
        throw describeAccountRegistryError(error)
      }
      guard !targets.isEmpty else {
        return CLICommandOutput(stdout: "", stderr: "Not signed in; nothing to log out.\n")
      }

      var removed: [AccountSession] = []
      var diagnostic = ""
      for target in targets {
        let store = try registry.sessionStore(for: target.did)
        if let session = try store.load() {
          diagnostic += await revokeDiagnostic(session)
        }
        do {
          removed.append(try registry.remove(target.did))
        } catch let error as AccountSessionRegistryError {
          throw describeAccountRegistryError(error)
        }
      }
      if json {
        return CLICommandOutput(stdout: try encodeAuthAccounts(removed), stderr: diagnostic)
      }
      let lines = removed.map { "Signed out @\($0.handle) (did: \($0.did))." }
      return CLICommandOutput(stdout: lines.joined(separator: "\n") + "\n", stderr: diagnostic)
    }
  }

  private func logoutExplicitStore(_ configured: CLISessionStore) async throws -> CLICommandOutput {
    let session: StoredSession?
    do {
      session = try configured.store.load()
    } catch let error as TangledError {
      try? configured.store.clear()
      throw CLICommandError.authentication(
        "failed to read stored session: \(describeTangledError(error))")
    }
    guard let session else {
      return CLICommandOutput(stdout: "", stderr: "Not signed in; nothing to log out.\n")
    }
    let diagnostic = await revokeDiagnostic(session)
    do {
      try configured.store.clear()
    } catch let error as TangledError {
      throw CLICommandError.authentication(
        "failed to clear stored session: \(describeTangledError(error))")
    }
    let account = AccountSession(did: session.did, handle: session.handle, isActive: true)
    if json {
      return CLICommandOutput(stdout: try encodeAuthAccounts([account]), stderr: diagnostic)
    }
    return CLICommandOutput(
      stdout: "Signed out @\(session.handle) (did: \(session.did)).\n", stderr: diagnostic)
  }

  private func revokeDiagnostic(_ session: StoredSession) async -> String {
    do {
      try await TokenRevoker(session: session).revoke()
      return ""
    } catch {
      return "warning: token revoke failed (\(error)); clearing local session anyway.\n"
    }
  }
}
