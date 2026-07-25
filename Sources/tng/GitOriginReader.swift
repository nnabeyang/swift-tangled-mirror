import Foundation

struct GitOriginReader: Sendable {
  func read() throws -> String {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["remote", "get-url", "origin"]
    process.standardOutput = standardOutput
    process.standardError = standardError

    do {
      try process.run()
    } catch {
      throw CLICommandError.git("failed to run git: \(error.localizedDescription)")
    }
    process.waitUntilExit()

    let output = String(
      decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, !output.isEmpty else {
      let diagnostic = String(
        decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      let detail = diagnostic.isEmpty ? "origin remote is not available" : diagnostic
      throw CLICommandError.git(
        "\(detail). Pass a repository explicitly as AT URI, repo DID, or handle/name."
      )
    }
    return output
  }
}
