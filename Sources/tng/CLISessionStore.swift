import ArgumentParser
import Foundation
import SwiftTangled

struct CLISessionStore {
  let store: any SessionStore
  let storageDescription: String
  let registry: AccountSessionRegistry?
  let account: AccountSession?

  static func make(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    account identifier: String? = CLIAccountOverride.identifier
  ) throws -> CLISessionStore {
    if let explicitPath = environment["TNG_SESSION_FILE"] {
      guard identifier == nil else {
        throw ValidationError("--account cannot be combined with TNG_SESSION_FILE")
      }
      guard !explicitPath.isEmpty, explicitPath.hasPrefix("/") else {
        throw CLICommandError.authentication("TNG_SESSION_FILE must be an absolute path")
      }
      let fileURL = URL(fileURLWithPath: explicitPath, isDirectory: false)
      return CLISessionStore(
        store: FileSessionStore(fileURL: fileURL),
        storageDescription: fileURL.path,
        registry: nil,
        account: nil
      )
    }

    let registry = try accountRegistry(environment: environment)
    do {
      let selected: AccountSession?
      if let identifier {
        selected = try registry.account(matching: identifier)
      } else {
        selected = try registry.activeAccount()
      }
      guard let selected else {
        return CLISessionStore(
          store: InMemorySessionStore(),
          storageDescription: "account registry",
          registry: registry,
          account: nil
        )
      }
      return CLISessionStore(
        store: try registry.sessionStore(for: selected.did),
        storageDescription: storageDescription(for: selected, environment: environment),
        registry: registry,
        account: selected
      )
    } catch let error as AccountSessionRegistryError {
      throw CLICommandError.authentication(error.localizedDescription)
    }
  }

  static func accountRegistry(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> AccountSessionRegistry {
    #if canImport(Security)
      AccountSessionRegistry(
        metadataStore: KeychainAccountRegistryStore(),
        sessionStoreFactory: { KeychainSessionStore(account: "account:\($0)") },
        legacyStore: KeychainSessionStore()
      )
    #else
      let directory = try linuxAccountsDirectoryURL(environment: environment)
      return AccountSessionRegistry(
        metadataStore: FileAccountRegistryStore(
          fileURL: directory.appendingPathComponent("registry.json", isDirectory: false)),
        sessionStoreFactory: { did in
          FileSessionStore(fileURL: sessionFileURL(accountsDirectory: directory, did: did))
        },
        legacyStore: FileSessionStore(fileURL: try linuxLegacySessionFileURL(environment: environment))
      )
    #endif
  }

  static func linuxLegacySessionFileURL(environment: [String: String]) throws -> URL {
    try stateDirectoryURL(environment: environment)
      .appendingPathComponent("session.json", isDirectory: false)
  }

  static func linuxSessionFileURL(environment: [String: String]) throws -> URL {
    try linuxLegacySessionFileURL(environment: environment)
  }

  static func linuxAccountsDirectoryURL(environment: [String: String]) throws -> URL {
    try stateDirectoryURL(environment: environment)
      .appendingPathComponent("accounts", isDirectory: true)
  }

  static func sessionFileURL(accountsDirectory: URL, did: String) -> URL {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
    let encoded = did.addingPercentEncoding(withAllowedCharacters: allowed) ?? did
    return accountsDirectory.appendingPathComponent("\(encoded).json", isDirectory: false)
  }

  private static func stateDirectoryURL(environment: [String: String]) throws -> URL {
    let basePath: String
    if let stateHome = environment["XDG_STATE_HOME"], !stateHome.isEmpty,
      stateHome.hasPrefix("/")
    {
      basePath = stateHome
    } else if let home = environment["HOME"], !home.isEmpty, home.hasPrefix("/") {
      basePath = URL(fileURLWithPath: home).appendingPathComponent(".local/state").path
    } else {
      throw CLICommandError.authentication(
        "cannot determine session storage location; set absolute XDG_STATE_HOME or HOME")
    }
    return URL(fileURLWithPath: basePath, isDirectory: true)
      .appendingPathComponent("tng", isDirectory: true)
  }

  private static func storageDescription(
    for account: AccountSession,
    environment: [String: String]
  ) -> String {
    #if canImport(Security)
      "macOS Keychain (service: \(KeychainSessionStore.defaultService), account: \(account.did))"
    #else
      (try? sessionFileURL(
        accountsDirectory: linuxAccountsDirectoryURL(environment: environment), did: account.did
      ).path) ?? "account registry"
    #endif
  }
}
