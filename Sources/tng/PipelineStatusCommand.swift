import ArgumentParser
import Foundation

struct PipelineStatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "View workflow statuses for a Tangled CI pipeline"
  )

  @Argument(help: "Spindle-local pipeline TID")
  var pipelineID: String

  @Option(
    name: .customLong("repo"),
    help: "Repository reference used to locate its Spindle (defaults to Git origin)"
  )
  var repository: String?

  @Option(help: "Spindle hostname or URL; skips repository discovery")
  var spindle: String?

  @Flag(help: "Output the workflow statuses as JSON")
  var json = false

  mutating func validate() throws {
    if let spindle, spindle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ValidationError("--spindle must not be empty")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PipelineCommandService(formatter: .live).status(
        pipelineID: pipelineID,
        repository: repository,
        spindle: spindle,
        json: json
      )
    }
  }
}
