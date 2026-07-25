import ArgumentParser
import Foundation
import SwiftTangled

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@main
struct Tng: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tng",
    abstract: "Tangled CLI",
    discussion: """
      Exit status:
        0   Success
        1   Unexpected failure
        3   Tangled SDK or API failure
        4   Authentication or session failure
        5   Git failure
        64  Invalid command usage
      """,
    version: SwiftTangled.version,
    subcommands: [
      AuthCommand.self,
      RepoCommand.self,
      ArtifactCommand.self,
      IssueCommand.self,
      PRCommand.self,
      PipelineCommand.self,
      EventsCommand.self,
      SearchCommand.self,
      APICommand.self,
      CompletionCommand.self,
      CapabilitiesCommand.self,
    ]
  )

  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    do {
      var command = try await asyncParseAsRoot(arguments)
      if var asyncCommand = command as? AsyncParsableCommand {
        try await asyncCommand.run()
      } else {
        try command.run()
      }
    } catch let exitCode as ExitCode {
      terminate(with: exitCode.rawValue)
    } catch let cleanExit as CleanExit {
      exit(withError: cleanExit)
    } catch {
      guard arguments.contains("--json") else {
        exit(withError: error)
      }
      writeCLIJSONError(
        CLIJSONErrorReport(
          category: "usage",
          code: "invalid_usage",
          message: message(for: error),
          exitCode: CLIExitCode.usage.rawValue
        )
      )
      terminate(with: CLIExitCode.usage.rawValue)
    }
  }
}

private func terminate(with code: Int32) -> Never {
  #if canImport(Darwin)
    Darwin.exit(code)
  #elseif canImport(Glibc)
    Glibc.exit(code)
  #else
    Foundation.exit(code)
  #endif
}
