import ArgumentParser
import SwiftTangled

struct AuthSwitchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "switch",
    abstract: "Select the active tng account"
  )

  @Argument(help: "Stored ATProto handle or DID")
  var account: String

  @Flag(help: "Output the selected account as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      let selected: AccountSession
      do {
        selected = try CLISessionStore.accountRegistry().switchActive(to: account)
      } catch let error as AccountSessionRegistryError {
        throw describeAccountRegistryError(error)
      }
      if json {
        return CLICommandOutput(stdout: try encodeAuthAccounts([selected]))
      }
      return CLICommandOutput(stdout: "Active account is now @\(selected.handle) (did: \(selected.did)).\n")
    }
  }
}
