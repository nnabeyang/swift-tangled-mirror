import Foundation
import SwiftTangled

struct AuthAccountOutput: Codable, Equatable, Sendable {
  let did: String
  let handle: String
  let active: Bool

  init(_ account: AccountSession) {
    did = account.did
    handle = account.handle
    active = account.isActive
  }
}

struct AuthAccountEnvelope: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let accounts: [AuthAccountOutput]

  init(accounts: [AuthAccountOutput]) {
    schemaVersion = 1
    self.accounts = accounts
  }
}

func encodeAuthAccounts(_ accounts: [AccountSession]) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return String(
    decoding: try encoder.encode(AuthAccountEnvelope(accounts: accounts.map(AuthAccountOutput.init))),
    as: UTF8.self
  ) + "\n"
}

func describeAccountRegistryError(_ error: AccountSessionRegistryError) -> CLICommandError {
  .authentication(error.localizedDescription)
}
