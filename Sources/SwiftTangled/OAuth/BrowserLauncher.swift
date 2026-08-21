import Foundation
import Subprocess

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

public protocol BrowserLauncher: Sendable {
  func open(_ url: URL) async throws
}

protocol BrowserCommandRunning: Sendable {
  func run(executableURL: URL, arguments: [String]) async throws -> Int32
}

struct SubprocessBrowserCommandRunner: BrowserCommandRunning {
  func run(executableURL: URL, arguments: [String]) async throws -> Int32 {
    var platformOptions = PlatformOptions()
    platformOptions.processGroupID = 0
    let result = try await Subprocess.run(
      .path(FilePath(executableURL.path)),
      arguments: Arguments(arguments),
      platformOptions: platformOptions,
      output: .currentStandardOutput,
      error: .currentStandardError
    )
    switch result.terminationStatus {
    case .exited(let code): return code
    case .signaled(let signal): return signal
    }
  }
}

public struct SystemBrowserLauncher: BrowserLauncher {
  private let executableURL: URL?
  private let runner: any BrowserCommandRunning

  public init() {
    executableURL = Self.systemExecutableURL()
    runner = SubprocessBrowserCommandRunner()
  }

  init(executableURL: URL?, runner: any BrowserCommandRunning) {
    self.executableURL = executableURL
    self.runner = runner
  }

  public func open(_ url: URL) async throws(TangledError) {
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
