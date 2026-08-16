import ArgumentParser
import SwiftTangled

struct AuthListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List stored tng accounts"
  )

  @Flag(help: "Output a versioned account list as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      let accounts: [AccountSession]
      do {
        accounts = try CLISessionStore.accountRegistry().accounts()
      } catch let error as AccountSessionRegistryError {
        throw describeAccountRegistryError(error)
      }
      if json {
        return CLICommandOutput(stdout: try encodeAuthAccounts(accounts))
      }
      guard !accounts.isEmpty else {
        return CLICommandOutput(stdout: "", stderr: "No stored accounts.\n")
      }
      let lines = accounts.map { account in
        "\(account.isActive ? "*" : " ") @\(account.handle)  \(account.did)"
      }
      return CLICommandOutput(stdout: lines.joined(separator: "\n") + "\n")
    }
  }
}
