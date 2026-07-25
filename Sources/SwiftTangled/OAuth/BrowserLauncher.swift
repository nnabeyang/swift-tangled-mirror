import Foundation

public protocol BrowserLauncher: Sendable {
  func open(_ url: URL) async throws
}

protocol BrowserCommandRunning: Sendable {
  func run(executableURL: URL, arguments: [String]) async throws -> Int32
}

private struct ProcessBrowserCommandRunner: BrowserCommandRunning {
  func run(executableURL: URL, arguments: [String]) async throws -> Int32 {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }
}

public struct SystemBrowserLauncher: BrowserLauncher {
  private let executableURL: URL?
  private let runner: any BrowserCommandRunning

  public init() {
    executableURL = Self.systemExecutableURL()
    runner = ProcessBrowserCommandRunner()
  }

  init(executableURL: URL?, runner: any BrowserCommandRunning) {
    self.executableURL = executableURL
    self.runner = runner
  }

  public func open(_ url: URL) async throws {
    guard let executableURL else {
      throw TangledError.browserLaunchFailed(
        "no supported browser launcher was found; use --no-browser --callback-port <port>"
      )
    }
    let status: Int32
    do {
      status = try await runner.run(
        executableURL: executableURL,
        arguments: [url.absoluteString]
      )
    } catch {
      throw TangledError.browserLaunchFailed(String(describing: error))
    }
    if status != 0 {
      throw TangledError.browserLaunchFailed(
        "\(executableURL.path) exited with status \(status)")
    }
  }

  private static func systemExecutableURL() -> URL? {
    #if os(Linux)
      let candidates = ["/usr/bin/xdg-open", "/usr/local/bin/xdg-open"]
    #else
      let candidates = ["/usr/bin/open"]
    #endif
    return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
      .map { URL(fileURLWithPath: $0) }
  }
}

extension BrowserLauncher where Self == SystemBrowserLauncher {
  public static var system: SystemBrowserLauncher { SystemBrowserLauncher() }
}
