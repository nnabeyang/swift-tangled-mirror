import Foundation
import SwiftTangled

enum CLIAuthenticatedClient {
  static func make(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> PDSClient {
    if let rawEndpoint = environment["TNG_AUTH_AGENT"] {
      guard !rawEndpoint.isEmpty else {
        throw CLICommandError.authentication("TNG_AUTH_AGENT must not be empty")
      }
      return try await PDSClient.authAgent(
        endpoint: AuthAgentEndpoint(environmentValue: rawEndpoint)
      )
    }
    return try PDSClient.restore(from: CLISessionStore.make(environment: environment).store)
  }
}
