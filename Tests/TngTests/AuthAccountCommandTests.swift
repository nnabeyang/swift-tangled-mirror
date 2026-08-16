import Foundation
import Testing

@testable import tng

@Suite struct AuthAccountCommandTests {
  @Test func extractsRootAccountAnywhereBeforeArgumentTerminator() throws {
    let leading = try CLIAccountOverride.extract(from: [
      "--account", "alice.test", "repo", "view",
    ])
    #expect(leading.account == "alice.test")
    #expect(leading.arguments == ["repo", "view"])

    let trailing = try CLIAccountOverride.extract(from: [
      "repo", "view", "--account=did:plc:alice",
    ])
    #expect(trailing.account == "did:plc:alice")
    #expect(trailing.arguments == ["repo", "view"])

    let terminated = try CLIAccountOverride.extract(from: [
      "api", "query", "--", "--account", "value",
    ])
    #expect(terminated.account == nil)
    #expect(terminated.arguments == ["api", "query", "--", "--account", "value"])
  }

  @Test func rejectsMissingDuplicateAndEmptyAccountOptions() {
    #expect(throws: (any Error).self) {
      _ = try CLIAccountOverride.extract(from: ["--account"])
    }
    #expect(throws: (any Error).self) {
      _ = try CLIAccountOverride.extract(from: ["--account="])
    }
    #expect(throws: (any Error).self) {
      _ = try CLIAccountOverride.extract(from: ["--account", "one", "--account", "two"])
    }
  }

  @Test func parsesAccountManagementCommands() throws {
    let list = try AuthListCommand.parse(["--json"])
    #expect(list.json)

    let selected = try AuthSwitchCommand.parse(["alice.test", "--json"])
    #expect(selected.account == "alice.test")
    #expect(selected.json)

    let logout = try AuthLogoutCommand.parse(["--all", "--json"])
    #expect(logout.all)
    #expect(logout.json)
  }

  @Test func createsFilesystemSafeAccountPaths() {
    let directory = URL(fileURLWithPath: "/var/lib/tng/accounts", isDirectory: true)
    let path = CLISessionStore.sessionFileURL(
      accountsDirectory: directory, did: "did:plc:alice/example"
    )
    #expect(path.path == "/var/lib/tng/accounts/did%3Aplc%3Aalice%2Fexample.json")
  }
}
