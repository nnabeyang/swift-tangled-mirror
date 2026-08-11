import Foundation
import SwiftTangled

struct CLISessionStore {
  let store: any SessionStore
  let storageDescription: String

  static func make(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> CLISessionStore {
    if let explicitPath = environment["TNG_SESSION_FILE"] {
      guard !explicitPath.isEmpty, explicitPath.hasPrefix("/") else {
        throw CLICommandError.authentication(
          "TNG_SESSION_FILE must be an absolute path"
        )
      }
      let fileURL = URL(fileURLWithPath: explicitPath, isDirectory: false)
      return CLISessionStore(
        store: FileSessionStore(fileURL: fileURL),
        storageDescription: fileURL.path
      )
    }
    #if canImport(Security)
      return CLISessionStore(
        store: KeychainSessionStore(),
        storageDescription:
          "macOS Keychain (service: \(KeychainSessionStore.defaultService))"
      )
    #else
      let fileURL = try linuxSessionFileURL(environment: environment)
      return CLISessionStore(
        store: FileSessionStore(fileURL: fileURL),
        storageDescription: fileURL.path
      )
    #endif
  }

  static func linuxSessionFileURL(environment: [String: String]) throws -> URL {
    let basePath: String
    if let stateHome = environment["XDG_STATE_HOME"],
      !stateHome.isEmpty,
      stateHome.hasPrefix("/")
    {
      basePath = stateHome
    } else if let home = environment["HOME"], !home.isEmpty, home.hasPrefix("/") {
      basePath =
        URL(fileURLWithPath: home)
        .appendingPathComponent(".local/state")
        .path
    } else {
      throw CLICommandError.authentication(
        "cannot determine session storage location; set absolute XDG_STATE_HOME or HOME"
      )
    }
    return URL(fileURLWithPath: basePath, isDirectory: true)
      .appendingPathComponent("tng", isDirectory: true)
      .appendingPathComponent("session.json", isDirectory: false)
  }
}
