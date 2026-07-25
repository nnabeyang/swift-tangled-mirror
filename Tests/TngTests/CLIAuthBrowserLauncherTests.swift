import Foundation
import SwiftTangled
import Testing

@testable import tng

@Suite
struct CLIAuthBrowserLauncherTests {
  @Test func automaticModeReportsAndOpensBrowser() async throws {
    let browser = RecordingBrowserLauncher()
    let output = LockedOutput()
    let launcher = CLIAuthBrowserLauncher(
      noBrowser: false,
      callbackPort: nil,
      systemBrowser: browser,
      output: { output.append($0) }
    )
    let url = URL(string: "https://auth.example/authorize")!

    try await launcher.open(url)

    #expect(browser.openedURL == url)
    #expect(output.value == "Opening browser for OAuth authorization…\n")
    #expect(!output.value.contains(url.absoluteString))
  }

  @Test func manualModePrintsURLPortForwardingAndDoesNotOpenBrowser() async throws {
    let browser = RecordingBrowserLauncher()
    let output = LockedOutput()
    let launcher = CLIAuthBrowserLauncher(
      noBrowser: true,
      callbackPort: 8765,
      systemBrowser: browser,
      output: { output.append($0) }
    )
    let url = URL(string: "https://auth.example/authorize?request_uri=abc")!

    try await launcher.open(url)

    #expect(browser.openedURL == nil)
    #expect(output.value.contains(url.absoluteString))
    #expect(output.value.contains("127.0.0.1:8765"))
    #expect(output.value.contains("ssh -N -L 8765:127.0.0.1:8765"))
    #expect(output.value.contains("Keep this command running"))
  }
}

private final class RecordingBrowserLauncher: BrowserLauncher, @unchecked Sendable {
  private let lock = NSLock()
  private var url: URL?

  var openedURL: URL? {
    lock.withLock { url }
  }

  func open(_ url: URL) async throws {
    lock.withLock {
      self.url = url
    }
  }
}

private final class LockedOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = ""

  var value: String {
    lock.withLock { storage }
  }

  func append(_ value: String) {
    lock.withLock {
      storage += value
    }
  }
}
