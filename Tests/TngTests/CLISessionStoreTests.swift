import Foundation
import Testing

@testable import tng

@Suite struct CLISessionStoreTests {
  @Test func usesAbsoluteXDGStateHome() throws {
    let url = try CLISessionStore.linuxSessionFileURL(
      environment: [
        "XDG_STATE_HOME": "/var/lib/example-state",
        "HOME": "/home/example",
      ]
    )

    #expect(url.path == "/var/lib/example-state/tng/session.json")
  }

  @Test func fallsBackToHomeForMissingEmptyOrRelativeXDGStateHome() throws {
    for stateHome in [nil, "", "relative/state"] {
      var environment = ["HOME": "/home/example"]
      if let stateHome {
        environment["XDG_STATE_HOME"] = stateHome
      }

      let url = try CLISessionStore.linuxSessionFileURL(environment: environment)

      #expect(url.path == "/home/example/.local/state/tng/session.json")
    }
  }

  @Test func rejectsMissingStorageBase() {
    #expect(throws: CLICommandError.self) {
      _ = try CLISessionStore.linuxSessionFileURL(environment: [:])
    }
    #expect(throws: CLICommandError.self) {
      _ = try CLISessionStore.linuxSessionFileURL(
        environment: [
          "XDG_STATE_HOME": "relative/state",
          "HOME": "relative/home",
        ]
      )
    }
  }
}
