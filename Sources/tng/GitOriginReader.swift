import Foundation
import Subprocess

struct GitOriginReader: Sendable {
  func read() async throws -> String {
    let result: ExecutionResult<Void, StringOutput<UTF8>, StringOutput<UTF8>>
    do {
      result = try await Subprocess.run(
        CLISubprocess.executable("/usr/bin/git"),
        arguments: ["remote", "get-url", "origin"],
        platformOptions: CLISubprocess.platformOptions,
        output: .string(limit: CLISubprocess.textOutputLimit),
        error: .string(limit: CLISubprocess.textOutputLimit)
      )
    } catch {
      throw CLICommandError.git("failed to run git: \(error)")
    }

    let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.terminationStatus.isSuccess, !output.isEmpty else {
      let diagnostic = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      let detail = diagnostic.isEmpty ? "origin remote is not available" : diagnostic
      throw CLICommandError.git(
        "\(detail). Pass a repository explicitly as AT URI, repo DID, or handle/name."
      )
    }
    return output
  }
}
