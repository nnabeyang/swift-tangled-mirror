import ArgumentParser
import Foundation
import SwiftTangled

struct AuthAgentServiceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "service",
    abstract: "Manage the macOS auth-agent LaunchAgent",
    subcommands: [
      AuthAgentServiceInstallCommand.self,
      AuthAgentServiceStartCommand.self,
      AuthAgentServiceStatusCommand.self,
      AuthAgentServiceRestartCommand.self,
      AuthAgentServiceStopCommand.self,
      AuthAgentServiceUninstallCommand.self,
    ]
  )
}

struct ServiceInstanceOptions: ParsableArguments {
  @Option(help: "Named service instance")
  var instance: String?

  @Flag(help: "Output service state as JSON")
  var json = false
}

struct AuthAgentServiceInstallCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "install",
    abstract: "Install and start a macOS auth-agent LaunchAgent"
  )

  @Option(name: .long, help: "Absolute ci-reporting session file path")
  var sessionFile: String

  @Option(name: .long, help: "Absolute Unix domain socket path")
  var socket: String

  @Option(name: .long, help: "Required authentication profile")
  var profile: String

  @Option(name: .long, help: "Absolute tng executable path")
  var executable: String?

  @Option(help: "Named service instance")
  var instance: String?

  @Option(name: .long, help: "Maximum request or response body size in bytes")
  var maxBodyBytes: UInt64 = AuthAgentProtocol.defaultMaximumBodyBytes

  @Option(name: .long, help: "Maximum attempted blob upload bytes per job")
  var maxJobUploadBytes: UInt64 = AuthAgentProtocol.defaultMaximumJobUploadBytes

  @Flag(help: "Output service state as JSON")
  var json = false

  mutating func validate() throws {
    guard sessionFile.hasPrefix("/") else {
      throw ValidationError("--session-file must be an absolute path")
    }
    guard socket.hasPrefix("/") else {
      throw ValidationError("--socket must be an absolute path")
    }
    guard profile == AuthenticationProfile.ciReporting.rawValue else {
      throw ValidationError("--profile must be 'ci-reporting'")
    }
    if let executable, !executable.hasPrefix("/") {
      throw ValidationError("--executable must be an absolute path")
    }
    guard maxBodyBytes > 0, maxJobUploadBytes > 0 else {
      throw ValidationError("auth-agent byte limits must be positive")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      let status = try await AuthAgentLaunchAgentService().install(
        configuration: AuthAgentServiceConfiguration(
          sessionFile: sessionFile,
          socketPath: socket,
          profile: .ciReporting,
          maximumBodyBytes: maxBodyBytes,
          maximumJobUploadBytes: maxJobUploadBytes
        ),
        executablePath: executable,
        instance: instance
      )
      return try serviceOutput(status, json: json, action: "installed")
    }
  }
}

struct AuthAgentServiceStartCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "start", abstract: "Start an installed auth-agent service")
  @OptionGroup var options: ServiceInstanceOptions

  func run() async throws {
    try await runCLICommand(jsonErrors: options.json) {
      let status = try await AuthAgentLaunchAgentService().start(instance: options.instance)
      return try serviceOutput(status, json: options.json, action: "started")
    }
  }
}

struct AuthAgentServiceStatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "status", abstract: "Show auth-agent service and health state")
  @OptionGroup var options: ServiceInstanceOptions

  func run() async throws {
    try await runCLICommand(jsonErrors: options.json) {
      let status = try await AuthAgentLaunchAgentService().status(instance: options.instance)
      return try serviceOutput(status, json: options.json, action: nil)
    }
  }
}

struct AuthAgentServiceRestartCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart an installed auth-agent service")
  @OptionGroup var options: ServiceInstanceOptions

  func run() async throws {
    try await runCLICommand(jsonErrors: options.json) {
      let status = try await AuthAgentLaunchAgentService().restart(instance: options.instance)
      return try serviceOutput(status, json: options.json, action: "restarted")
    }
  }
}

struct AuthAgentServiceStopCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop an auth-agent service without uninstalling it")
  @OptionGroup var options: ServiceInstanceOptions

  func run() async throws {
    try await runCLICommand(jsonErrors: options.json) {
      let status = try await AuthAgentLaunchAgentService().stop(instance: options.instance)
      return try serviceOutput(status, json: options.json, action: "stopped")
    }
  }
}

struct AuthAgentServiceUninstallCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Stop and remove an auth-agent LaunchAgent")
  @OptionGroup var options: ServiceInstanceOptions

  func run() async throws {
    try await runCLICommand(jsonErrors: options.json) {
      let status = try await AuthAgentLaunchAgentService().uninstall(instance: options.instance)
      return try serviceOutput(status, json: options.json, action: "uninstalled")
    }
  }
}

private func serviceOutput(
  _ status: AuthAgentServiceStatus,
  json: Bool,
  action: String?
) throws -> CLICommandOutput {
  if json {
    return CLICommandOutput(stdout: try CLIFormatter.live.json(status))
  }
  let prefix = action.map { "\($0) " } ?? ""
  var fields = [
    "label=\(status.label)",
    "state=\(status.state.rawValue)",
    "session=\(status.sessionState.rawValue)",
    "socket=\(status.socketState.rawValue)",
  ]
  if let pid = status.pid { fields.append("pid=\(pid)") }
  if let handle = status.handle { fields.append("handle=\(handle)") }
  return CLICommandOutput(stdout: prefix + fields.joined(separator: " ") + "\n")
}
