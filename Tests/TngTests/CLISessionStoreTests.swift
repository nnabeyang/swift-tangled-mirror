import Foundation
import Testing

@testable import tng

@Suite struct CLISessionStoreTests {
  @Test func explicitSessionFileOverridesPlatformDefault() throws {
    let store = try CLISessionStore.make(
      environment: ["TNG_SESSION_FILE": "/var/lib/tng/ci-session.json"]
    )
    #expect(store.storageDescription == "/var/lib/tng/ci-session.json")
  }

  @Test func rejectsRelativeExplicitSessionFile() {
    #expect(throws: CLICommandError.self) {
      _ = try CLISessionStore.make(environment: ["TNG_SESSION_FILE": "session.json"])
    }
  }

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
