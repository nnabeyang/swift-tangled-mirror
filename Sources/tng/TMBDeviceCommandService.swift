import ArgumentParser
import Foundation
import SwiftTangled

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct TMBDeviceCommandDependencies: Sendable {
  let store: @Sendable (String) throws -> any TMBDeviceCredentialStoring
  let enroll: @Sendable (TMBOrigin, String, String) async throws -> TMBDeviceCredentials
  let revoke: @Sendable (TMBOrigin, TMBDeviceCredentials) async throws -> Bool
  let inputIsTerminal: @Sendable () -> Bool
  let confirmRevocation: @Sendable (TMBDeviceRegistration) -> Bool

  static let live = TMBDeviceCommandDependencies(
    store: { instance in
      FileTMBDeviceCredentialStore(
        fileURL: try CLITMBDeviceStore.fileURL(instance: instance)
      )
    },
    enroll: { origin, name, secret in
      try await TMBClient(origin: origin).enroll(name: name, credential: secret)
    },
    revoke: { origin, credentials in
      try await TMBClient(origin: origin, credentials: credentials).revokeDevice()
    },
    inputIsTerminal: { tmbStandardInputIsTerminal() },
    confirmRevocation: { promptForTMBDeviceRevocation($0) }
  )
}

struct TMBDeviceCommandResult: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let action: String
  let instance: String
  let configured: Bool
  let origin: String?
  let deviceID: String?

  init(
    action: String,
    instance: String,
    configured: Bool,
    origin: String? = nil,
    deviceID: String? = nil
  ) {
    schemaVersion = 1
    self.action = action
    self.instance = instance
    self.configured = configured
    self.origin = origin
    self.deviceID = deviceID
  }
}

struct TMBDeviceCommandService: Sendable {
  var formatter: CLIFormatter
  var dependencies: TMBDeviceCommandDependencies

  static let live = TMBDeviceCommandService(
    formatter: .live,
    dependencies: .live
  )

  func enroll(
    instance: String,
    origin: String,
    name: String,
    secret: String,
    json: Bool
  ) async throws -> CLICommandOutput {
    try validate(instance: instance)
    guard !name.isEmpty else { throw ValidationError("--name must not be empty") }
    guard !secret.isEmpty else {
      throw CLICommandError.authenticationRequired("TMB enrollment credential is required")
    }
    let resolvedOrigin = try TMBOrigin(origin)
    let store = try dependencies.store(instance)
    guard try store.load() == nil else {
      throw CLICommandError.authentication(
        "TMB instance '\(instance)' is already enrolled; revoke it before enrolling again"
      )
    }
    let credentials = try await dependencies.enroll(resolvedOrigin, name, secret)
    let registration = try TMBDeviceRegistration(
      instance: instance,
      origin: resolvedOrigin,
      credentials: credentials
    )
    do {
      try store.write(registration)
    } catch {
      _ = try? await dependencies.revoke(resolvedOrigin, credentials)
      throw error
    }
    return try output(action: "enrolled", registration: registration, json: json)
  }

  func status(instance: String, json: Bool) throws -> CLICommandOutput {
    try validate(instance: instance)
    let registration = try dependencies.store(instance).load()
    guard let registration else {
      let result = TMBDeviceCommandResult(
        action: "status",
        instance: instance,
        configured: false
      )
      return CLICommandOutput(
        stdout: try json
          ? formatter.json(result)
          : "TMB instance '\(instance)' is not enrolled.\n"
      )
    }
    return try output(action: "status", registration: registration, json: json)
  }

  func revoke(
    instance: String,
    confirmed: Bool,
    json: Bool
  ) async throws -> CLICommandOutput {
    try validate(instance: instance)
    let store = try dependencies.store(instance)
    guard let registration = try store.load() else {
      let result = TMBDeviceCommandResult(
        action: "revoke",
        instance: instance,
        configured: false
      )
      return CLICommandOutput(
        stdout: try json
          ? formatter.json(result)
          : "TMB instance '\(instance)' is not enrolled; nothing to revoke.\n"
      )
    }
    if !confirmed {
      guard dependencies.inputIsTerminal() else {
        throw ValidationError("--yes is required when standard input is not a terminal")
      }
      guard dependencies.confirmRevocation(registration) else {
        return CLICommandOutput(stdout: "Revocation cancelled.\n")
      }
    }
    guard try await dependencies.revoke(registration.origin, registration.credentials) else {
      throw TMBClientError.invalidResponse
    }
    try store.clear()
    let result = TMBDeviceCommandResult(
      action: "revoked",
      instance: instance,
      configured: false,
      origin: registration.origin.url.absoluteString,
      deviceID: registration.credentials.deviceID
    )
    return CLICommandOutput(
      stdout: try json
        ? formatter.json(result)
        : "Revoked TMB device \(registration.credentials.deviceID) for instance '\(instance)'.\n"
    )
  }

  private func output(
    action: String,
    registration: TMBDeviceRegistration,
    json: Bool
  ) throws -> CLICommandOutput {
    let result = TMBDeviceCommandResult(
      action: action,
      instance: registration.instance,
      configured: true,
      origin: registration.origin.url.absoluteString,
      deviceID: registration.credentials.deviceID
    )
    if json { return CLICommandOutput(stdout: try formatter.json(result)) }
    switch action {
    case "enrolled":
      return CLICommandOutput(
        stdout:
          "Enrolled TMB device \(registration.credentials.deviceID) for instance '\(registration.instance)' at \(registration.origin.url.absoluteString).\n"
      )
    default:
      return CLICommandOutput(
        stdout:
          "TMB instance '\(registration.instance)' is enrolled at \(registration.origin.url.absoluteString) as device \(registration.credentials.deviceID).\n"
      )
    }
  }

  private func validate(instance: String) throws {
    guard TMBDeviceRegistration.validInstance(instance) else {
      throw ValidationError(TMBDeviceCredentialStoreError.invalidInstance.localizedDescription)
    }
  }
}

enum CLITMBDeviceStore {
  static func fileURL(
    instance: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> URL {
    guard TMBDeviceRegistration.validInstance(instance) else {
      throw TMBDeviceCredentialStoreError.invalidInstance
    }
    let baseURL: URL
    #if os(macOS)
      guard let home = environment["HOME"], home.hasPrefix("/") else {
        throw TMBDeviceCredentialStoreError.unavailable("HOME must be an absolute path")
      }
      baseURL = URL(fileURLWithPath: home, isDirectory: true)
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    #else
      if let stateHome = environment["XDG_STATE_HOME"], stateHome.hasPrefix("/") {
        baseURL = URL(fileURLWithPath: stateHome, isDirectory: true)
      } else if let home = environment["HOME"], home.hasPrefix("/") {
        baseURL = URL(fileURLWithPath: home, isDirectory: true)
          .appendingPathComponent(".local/state", isDirectory: true)
      } else {
        throw TMBDeviceCredentialStoreError.unavailable(
          "XDG_STATE_HOME or HOME must be an absolute path"
        )
      }
    #endif
    return
      baseURL
      .appendingPathComponent("tng/tmb", isDirectory: true)
      .appendingPathComponent(instance, isDirectory: true)
      .appendingPathComponent("device.json", isDirectory: false)
  }
}

private func tmbStandardInputIsTerminal() -> Bool {
  #if canImport(Darwin)
    Darwin.isatty(FileHandle.standardInput.fileDescriptor) == 1
  #elseif canImport(Glibc)
    Glibc.isatty(FileHandle.standardInput.fileDescriptor) == 1
  #else
    false
  #endif
}

private func promptForTMBDeviceRevocation(_ registration: TMBDeviceRegistration) -> Bool {
  FileHandle.standardError.write(
    Data(
      "Revoke TMB device \(registration.credentials.deviceID) for instance '\(registration.instance)'? [y/N] "
        .utf8
    )
  )
  guard let answer = readLine()?.lowercased() else { return false }
  return answer == "y" || answer == "yes"
}
