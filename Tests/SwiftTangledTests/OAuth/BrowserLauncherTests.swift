import Foundation
import Testing

@testable import SwiftTangled

@Suite
struct BrowserLauncherTests {
  @Test func systemLauncherPassesURLAsSingleArgumentWithoutShell() async throws {
    let runner = RecordingBrowserCommandRunner(status: 0)
    let executable = URL(fileURLWithPath: "/test/xdg-open")
    let launcher = SystemBrowserLauncher(
      executableURL: executable,
      runner: runner
    )
    let authorizationURL = URL(
      string: "https://auth.example/authorize?state=a%20b&redirect_uri=http://127.0.0.1")!

    try await launcher.open(authorizationURL)

    #expect(runner.executableURL == executable)
    #expect(runner.arguments == [authorizationURL.absoluteString])
  }

  @Test func missingSystemCommandProducesTypedFailure() async {
    let launcher = SystemBrowserLauncher(
      executableURL: nil,
      runner: RecordingBrowserCommandRunner(status: 0)
    )

    do {
      try await launcher.open(URL(string: "https://auth.example")!)
      Issue.record("Expected browserLaunchFailed")
    } catch TangledError.browserLaunchFailed(let message) {
      #expect(message.contains("--no-browser --callback-port"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func nonzeroSystemCommandExitProducesTypedFailure() async {
    let launcher = SystemBrowserLauncher(
      executableURL: URL(fileURLWithPath: "/test/xdg-open"),
      runner: RecordingBrowserCommandRunner(status: 3)
    )

    do {
      try await launcher.open(URL(string: "https://auth.example")!)
      Issue.record("Expected browserLaunchFailed")
    } catch TangledError.browserLaunchFailed(let message) {
      #expect(message.contains("status 3"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

private final class RecordingBrowserCommandRunner: BrowserCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private let status: Int32
  private var recordedExecutableURL: URL?
  private var recordedArguments: [String] = []

  init(status: Int32) {
    self.status = status
  }

  var executableURL: URL? {
    lock.withLock { recordedExecutableURL }
  }

  var arguments: [String] {
    lock.withLock { recordedArguments }
  }

  func run(executableURL: URL, arguments: [String]) async throws -> Int32 {
    lock.withLock {
      recordedExecutableURL = executableURL
      recordedArguments = arguments
    }
    return status
  }
}

@Suite struct SubprocessBrowserCommandRunnerTests {
  @Test(arguments: [("/usr/bin/true", Int32(0)), ("/usr/bin/false", Int32(1))])
  func reportsTheExitStatusOfTheLaunchedCommand(executable: String, status: Int32) async throws {
    let reported = try await SubprocessBrowserCommandRunner().run(
      executableURL: URL(fileURLWithPath: executable),
      arguments: []
    )

    #expect(reported == status)
  }
}
