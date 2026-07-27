import Foundation

struct TngProcessResult {
  let status: Int32
  let stdout: String
  let stderr: String
}

enum TngProcess {
  static func run(
    _ arguments: [String],
    currentDirectory: URL? = nil,
    environment overrides: [String: String] = [:]
  ) throws -> TngProcessResult {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = try executableURL()
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.standardOutput = standardOutput
    process.standardError = standardError
    var environment = ProcessInfo.processInfo.environment
    environment["NO_COLOR"] = "1"
    for (key, value) in overrides {
      environment[key] = value
    }
    process.environment = environment

    try process.run()
    process.waitUntilExit()

    return TngProcessResult(
      status: process.terminationStatus,
      stdout: String(
        decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
      ),
      stderr: String(
        decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
      )
    )
  }

  static func executableURL() throws -> URL {
    let bundle = Bundle(for: TngTestBundleAnchor.self)
    var productDirectories = [
      bundle.bundleURL,
      bundle.bundleURL.deletingLastPathComponent(),
      URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
    ]
    if let bundleExecutableURL = bundle.executableURL {
      productDirectories.append(bundleExecutableURL.deletingLastPathComponent())
    }

    var seenPaths = Set<String>()
    let candidates = productDirectories.compactMap { directory -> URL? in
      let candidate =
        directory
        .appendingPathComponent("tng")
        .standardizedFileURL
      return seenPaths.insert(candidate.path).inserted ? candidate : nil
    }
    if let executable = candidates.first(where: {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }) {
      return executable
    }
    throw TngProcessError.executableNotFound(candidates.map(\.path))
  }
}

private final class TngTestBundleAnchor: NSObject {}

private enum TngProcessError: Error {
  case executableNotFound([String])
}
