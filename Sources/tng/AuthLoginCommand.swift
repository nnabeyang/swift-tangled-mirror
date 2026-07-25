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

  mutating func validate() throws {
    if noBrowser, callbackPort == nil {
      throw ValidationError("--callback-port is required with --no-browser")
    }
    if callbackPort == 0 {
      throw ValidationError("--callback-port must be between 1 and 65535")
    }
  }

  func run() async throws {
    try await runCLICommand {
      let sessionStore = try CLISessionStore.make()
      let browser = CLIAuthBrowserLauncher(
        noBrowser: noBrowser,
        callbackPort: callbackPort
      )
      let flow = AuthFlow(
        browser: browser,
        sessionStore: sessionStore.store,
        callbackPort: callbackPort
      )
      let result = try await flow.login(handle: handle)
      return CLICommandOutput(
        stdout: "Signed in as @\(result.handle) (did: \(result.did))\n",
        stderr: "Session stored in \(sessionStore.storageDescription)\n"
      )
    }
  }
}
