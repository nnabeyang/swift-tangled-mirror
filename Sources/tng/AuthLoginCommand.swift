import ArgumentParser
import Foundation
import SwiftTangled

struct AuthLoginCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "login",
    abstract: "Sign in to Tangled via ATProto OAuth"
  )

  @Argument(help: "ATProto handle to sign in as (例: alice.bsky.social)")
  var handle: String

  @Flag(
    name: .long,
    help: "Print the authorization URL instead of opening a browser"
  )
  var noBrowser = false

  @Option(
    name: .long,
    help: "Bind the OAuth callback server to a fixed loopback port"
  )
  var callbackPort: UInt16?

  @Option(name: .long, help: "Use a restricted authentication profile")
  var profile: String?

  mutating func validate() throws {
    if ProcessInfo.processInfo.environment["TNG_AUTH_AGENT"] != nil {
      throw ValidationError("auth login is unavailable while TNG_AUTH_AGENT is set")
    }
    if noBrowser, callbackPort == nil {
      throw ValidationError("--callback-port is required with --no-browser")
    }
    if callbackPort == 0 {
      throw ValidationError("--callback-port must be between 1 and 65535")
    }
    if let profile {
      guard AuthenticationProfile(rawValue: profile) != nil else {
        throw ValidationError("--profile must be 'ci-reporting'")
      }
      let path = ProcessInfo.processInfo.environment["TNG_SESSION_FILE"] ?? ""
      if !path.hasPrefix("/") {
        throw ValidationError("--profile requires an absolute TNG_SESSION_FILE")
      }
    }
  }

  func run() async throws {
    try await runCLICommand {
      let configuredStore = try CLISessionStore.make()
      let loginStore: any SessionStore =
        configuredStore.registry == nil ? configuredStore.store : InMemorySessionStore()
      let browser = CLIAuthBrowserLauncher(
        noBrowser: noBrowser,
        callbackPort: callbackPort
      )
      let flow = AuthFlow(
        browser: browser,
        sessionStore: loginStore,
        callbackPort: callbackPort,
        profile: profile.flatMap(AuthenticationProfile.init(rawValue:))
      )
      let result = try await flow.login(handle: handle)
      var storageDescription = configuredStore.storageDescription
      if let registry = configuredStore.registry {
        guard let session = try loginStore.load(), session.did == result.did else {
          throw CLICommandError.authentication("OAuth login did not produce a stored session")
        }
        try registry.store(session)
        storageDescription = try CLISessionStore.make(account: result.did).storageDescription
      }
      return CLICommandOutput(
        stdout: "Signed in as @\(result.handle) (did: \(result.did))\n",
        stderr: "Session stored in \(storageDescription)\n"
      )
    }
  }
}
