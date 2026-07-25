import Foundation
import SwiftTangled

struct CLIAuthBrowserLauncher: BrowserLauncher {
  private let noBrowser: Bool
  private let callbackPort: UInt16?
  private let systemBrowser: any BrowserLauncher
  private let output: @Sendable (String) -> Void

  init(
    noBrowser: Bool,
    callbackPort: UInt16?,
    systemBrowser: any BrowserLauncher = .system,
    output: @escaping @Sendable (String) -> Void = { message in
      FileHandle.standardError.write(Data(message.utf8))
    }
  ) {
    self.noBrowser = noBrowser
    self.callbackPort = callbackPort
    self.systemBrowser = systemBrowser
    self.output = output
  }

  func open(_ url: URL) async throws {
    if noBrowser {
      guard let callbackPort else {
        throw TangledError.invalidRequest(
          "--callback-port is required with --no-browser"
        )
      }
      output(
        """
        Open this URL in a browser:
        \(url.absoluteString)

        Forward local port \(callbackPort) to 127.0.0.1:\(callbackPort) in this environment.
        For SSH, run in another terminal:
          ssh -N -L \(callbackPort):127.0.0.1:\(callbackPort) <host>
        Keep this command running until authorization completes.

        """
      )
      return
    }

    output("Opening browser for OAuth authorization…\n")
    try await systemBrowser.open(url)
  }
}
