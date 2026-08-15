import ArgumentParser
import Foundation
import SwiftTangled

struct AuthAgentTMBCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tmb",
    abstract: "Manage a token-mediating backend device",
    subcommands: [
      AuthAgentTMBEnrollCommand.self,
      AuthAgentTMBStatusCommand.self,
      AuthAgentTMBRevokeCommand.self,
    ]
  )
}

struct TMBInstanceOptions: ParsableArguments {
  @Option(help: "Named TMB instance")
  var instance: String?

  @Flag(help: "Output a versioned result as JSON")
  var json = false

  var resolvedInstance: String { instance ?? "default" }
}

struct AuthAgentTMBEnrollCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "enroll",
    abstract: "Enroll this client as a TMB device"
  )

  @Option(help: "TMB HTTPS origin")
  var origin: String

  @Option(help: "Device name shown to the TMB administrator")
  var name: String

  @OptionGroup var options: TMBInstanceOptions

  mutating func validate() throws {
    guard !name.isEmpty else { throw ValidationError("--name must not be empty") }
    guard TMBDeviceRegistration.validInstance(options.resolvedInstance) else {
      throw ValidationError(TMBDeviceCredentialStoreError.invalidInstance.localizedDescription)
    }
    _ = try TMBOrigin(origin)
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: options.json) {
      let secret = try CLISecretReader().read()
      return try await TMBDeviceCommandService.live.enroll(
        instance: options.resolvedInstance,
        origin: origin,
        name: name,
        secret: secret,
        json: options.json
      )
    }
  }
}

struct AuthAgentTMBStatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show locally stored TMB device state"
  )

  @OptionGroup var options: TMBInstanceOptions

  mutating func validate() throws {
    guard TMBDeviceRegistration.validInstance(options.resolvedInstance) else {
      throw ValidationError(TMBDeviceCredentialStoreError.invalidInstance.localizedDescription)
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: options.json) {
      try TMBDeviceCommandService.live.status(
        instance: options.resolvedInstance,
        json: options.json
      )
    }
  }
}

struct AuthAgentTMBRevokeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "revoke",
    abstract: "Revoke a TMB device and all sessions it owns"
  )

  @OptionGroup var options: TMBInstanceOptions

  @Flag(help: "Revoke without an interactive confirmation")
  var yes = false

  mutating func validate() throws {
    guard TMBDeviceRegistration.validInstance(options.resolvedInstance) else {
      throw ValidationError(TMBDeviceCredentialStoreError.invalidInstance.localizedDescription)
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: options.json) {
      try await TMBDeviceCommandService.live.revoke(
        instance: options.resolvedInstance,
        confirmed: yes,
        json: options.json
      )
    }
  }
}
