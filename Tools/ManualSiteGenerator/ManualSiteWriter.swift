import Foundation

enum ManualSiteError: Error, CustomStringConvertible {
  case invalidArguments(String)
  case toolFailed(Int32)
  case unsupportedSerializationVersion(Int)
  case missingRootCommand
  case unsafeOutputPath(String)

  var description: String {
    switch self {
    case .invalidArguments(let message):
      return message
    case .toolFailed(let status):
      return "tng --experimental-dump-help failed with exit status \(status)"
    case .unsupportedSerializationVersion(let version):
      return "Unsupported ArgumentParser dump-help serialization version \(version); expected 0"
    case .missingRootCommand:
      return "The ArgumentParser command tree does not contain a visible root command"
    case .unsafeOutputPath(let path):
      return "Refusing to modify an unsafe manual site output path: \(path)"
    }
  }
}

struct ManualSiteWriter {
  private let fileManager = FileManager.default

  func loadToolInfo(toolURL: URL) throws -> ToolInfo {
    let process = Process()
    let output = Pipe()
    process.executableURL = toolURL
    process.arguments = ["--experimental-dump-help"]
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ManualSiteError.toolFailed(process.terminationStatus)
    }
    return try JSONDecoder().decode(ToolInfo.self, from: data)
  }

  func write(files: [String: Data], outputDirectory: URL) throws {
    let output = outputDirectory.standardizedFileURL
    guard output.lastPathComponent == "generated", output.pathComponents.count > 2 else {
      throw ManualSiteError.unsafeOutputPath(output.path)
    }

    if fileManager.fileExists(atPath: output.path) {
      try fileManager.removeItem(at: output)
    }
    try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

    for (path, data) in files {
      let destination = output.appendingPathComponent(path).standardizedFileURL
      guard destination.path.hasPrefix(output.path + "/") else {
        throw ManualSiteError.unsafeOutputPath(destination.path)
      }
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: destination, options: .atomic)
    }
  }

}
