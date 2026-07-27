import Foundation

enum ManualSiteError: Error, CustomStringConvertible {
  case invalidArguments(String)
  case toolFailed(Int32)
  case unsupportedSerializationVersion(Int)
  case missingRootCommand
  case missingSourceFile(String)
  case unsafeOutputPath(String)
  case generatedFilesDiffer([String])

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
    case .missingSourceFile(let path):
      return "Required manual site source is missing: \(path)"
    case .unsafeOutputPath(let path):
      return "Refusing to modify an unsafe manual site output path: \(path)"
    case .generatedFilesDiffer(let differences):
      return "Generated manual site is out of date:\n" + differences.map { "  \($0)" }.joined(separator: "\n")
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

  func loadSource(directory: URL) throws -> ManualSiteSource {
    ManualSiteSource(
      landingHTML: try read("landing.html", from: directory),
      stylesheet: try read("manual.css", from: directory),
      javascript: try read("manual.js", from: directory)
    )
  }

  func check(files: [String: Data], outputDirectory: URL) throws {
    let actual = try ownedFiles(in: outputDirectory)
    let expectedPaths = Set(files.keys)
    let actualPaths = Set(actual.keys)
    var differences: [String] = []

    for path in expectedPaths.subtracting(actualPaths).sorted() {
      differences.append("missing \(path)")
    }
    for path in actualPaths.subtracting(expectedPaths).sorted() {
      differences.append("unexpected \(path)")
    }
    for path in expectedPaths.intersection(actualPaths).sorted()
    where files[path] != actual[path] {
      differences.append("changed \(path)")
    }

    guard differences.isEmpty else {
      throw ManualSiteError.generatedFilesDiffer(differences)
    }
  }

  func write(files: [String: Data], outputDirectory: URL) throws {
    let output = outputDirectory.standardizedFileURL
    guard output.lastPathComponent == "docs", output.pathComponents.count > 2 else {
      throw ManualSiteError.unsafeOutputPath(output.path)
    }

    try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
    for ownedPath in ["index.html", "manual", "assets"] {
      let target = output.appendingPathComponent(ownedPath).standardizedFileURL
      guard target.path.hasPrefix(output.path + "/") else {
        throw ManualSiteError.unsafeOutputPath(target.path)
      }
      if fileManager.fileExists(atPath: target.path) {
        try fileManager.removeItem(at: target)
      }
    }

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

  private func read(_ name: String, from directory: URL) throws -> String {
    let url = directory.appendingPathComponent(name)
    guard let value = try? String(contentsOf: url, encoding: .utf8) else {
      throw ManualSiteError.missingSourceFile(url.path)
    }
    return value
  }

  private func ownedFiles(in outputDirectory: URL) throws -> [String: Data] {
    let output = outputDirectory.standardizedFileURL
    guard fileManager.fileExists(atPath: output.path) else { return [:] }
    var files: [String: Data] = [:]
    let rootIndex = output.appendingPathComponent("index.html")
    if fileManager.fileExists(atPath: rootIndex.path) {
      files["index.html"] = try Data(contentsOf: rootIndex)
    }
    for directoryName in ["manual", "assets"] {
      let directory = output.appendingPathComponent(directoryName)
      guard
        let enumerator = fileManager.enumerator(
          at: directory,
          includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles]
        )
      else { continue }
      for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let prefix = output.path.hasSuffix("/") ? output.path : output.path + "/"
        guard url.path.hasPrefix(prefix) else {
          throw ManualSiteError.unsafeOutputPath(url.path)
        }
        files[String(url.path.dropFirst(prefix.count))] = try Data(contentsOf: url)
      }
    }
    return files
  }
}
