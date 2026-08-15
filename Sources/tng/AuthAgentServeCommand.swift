import ArgumentParser
import Foundation
import SwiftTangled

struct AuthAgentServeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "serve",
    abstract: "Serve a restricted OAuth session over a Unix socket"
  )

  @Option(name: .long, help: "Absolute Unix domain socket path")
  var socket: String

  @Option(name: .long, help: "Required authentication profile")
  var profile: String

  @Option(name: .long, help: "Named TMB instance used instead of TNG_SESSION_FILE")
  var tmbInstance: String?

  @Option(name: .long, help: "Maximum request or response body size in bytes")
  var maxBodyBytes: UInt64 = AuthAgentProtocol.defaultMaximumBodyBytes

  @Option(name: .long, help: "Maximum attempted blob upload bytes per job")
  var maxJobUploadBytes: UInt64 = AuthAgentProtocol.defaultMaximumJobUploadBytes

  mutating func validate() throws {
    guard socket.hasPrefix("/") else {
      throw ValidationError("--socket must be an absolute path")
    }
    guard profile == AuthenticationProfile.ciReporting.rawValue else {
      throw ValidationError("--profile must be 'ci-reporting'")
    }
    guard maxBodyBytes > 0, maxJobUploadBytes > 0 else {
      throw ValidationError("auth-agent byte limits must be positive")
    }
    let sessionPath = ProcessInfo.processInfo.environment["TNG_SESSION_FILE"]
    if let tmbInstance {
      guard TMBDeviceRegistration.validInstance(tmbInstance) else {
        throw ValidationError(TMBDeviceCredentialStoreError.invalidInstance.localizedDescription)
      }
      guard sessionPath == nil || sessionPath?.isEmpty == true else {
        throw ValidationError("--tmb-instance cannot be combined with TNG_SESSION_FILE")
      }
    } else {
      guard sessionPath?.hasPrefix("/") == true else {
        throw ValidationError(
          "auth agent serve requires an absolute TNG_SESSION_FILE or --tmb-instance")
      }
    }
  }

  func run() async throws {
    try await runCLICommand {
      let configuration = AuthAgentServerConfiguration(
        socketPath: socket,
        profile: .ciReporting,
        maximumBodyBytes: maxBodyBytes,
        maximumJobUploadBytes: maxJobUploadBytes
      )
      let server: AuthAgentServer
      if let tmbInstance {
        let context = try CLITMBSessionContext.make(instance: tmbInstance)
        server = try AuthAgentServer(
          configuration: configuration,
          authentication: AuthAgentAuthentication(
            accountDID: context.session.accountDID,
            handle: context.session.handle,
            profile: .ciReporting,
            authorizedScopes: ["atproto", "transition:generic"],
            client: context.agent
          ))
      } else {
        let sessionStore = try CLISessionStore.make()
        server = try AuthAgentServer(
          configuration: configuration,
          sessionStore: sessionStore.store
        )
      }
      writeHumanDiagnostic(
        "Serving ci-reporting auth-agent on \(socket)\(tmbInstance.map { " with TMB instance '\($0)'" } ?? "") (body: \(maxBodyBytes) bytes, job uploads: \(maxJobUploadBytes) bytes).\n"
      )
      try await server.serve()
      return CLICommandOutput(stdout: "")
    }
  }
}
