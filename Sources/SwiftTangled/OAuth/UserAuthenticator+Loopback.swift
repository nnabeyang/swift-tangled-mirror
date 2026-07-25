import Foundation
import OAuth4Swift

public enum LoopbackUserAuthenticator {
  public static func make(
    server: LoopbackCallbackServer,
    browser: any BrowserLauncher = .system,
    timeout: Duration = .seconds(300)
  ) -> UserAuthenticator {
    { authURL, _ in
      try await browser.open(authURL)
      return try await server.waitForCallback(timeout: timeout)
    }
  }
}
