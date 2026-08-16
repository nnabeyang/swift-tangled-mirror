import Foundation
import ArgumentParser
import SwiftTangled

enum CLIAuthenticatedClient {
  static func make(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    account: String? = CLIAccountOverride.identifier
  ) async throws -> PDSClient {
    if let rawEndpoint = environment["TNG_AUTH_AGENT"] {
      guard account == nil else {
        throw ValidationError("--account cannot be combined with TNG_AUTH_AGENT")
      }
      guard !rawEndpoint.isEmpty else {
        throw CLICommandError.authentication("TNG_AUTH_AGENT must not be empty")
      }
      return try await PDSClient.authAgent(
        endpoint: AuthAgentEndpoint(environmentValue: rawEndpoint)
      )
    }
    return try PDSClient.restore(
      from: CLISessionStore.make(environment: environment, account: account).store)
  }
}
