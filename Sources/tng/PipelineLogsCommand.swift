import ArgumentParser
import Foundation

struct PipelineLogsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "logs",
    abstract: "Stream logs from a Tangled CI pipeline"
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

  @Option(
    parsing: .unconditionalSingleValue,
    help: "Stream only the named workflow; repeat for multiple workflows"
  )
  var workflow: [String] = []

  @Flag(help: "Output one compact pipeline log JSON object per event")
  var json = false

  mutating func validate() throws {
    if let spindle, spindle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ValidationError("--spindle must not be empty")
    }
    if workflow.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
      throw ValidationError("--workflow must not be empty")
    }
  }

  func run() async throws {
    try await runCLIStreamingCommand(jsonErrors: json) {
      try await PipelineCommandService(formatter: .live).logs(
        pipelineID: pipelineID,
        repository: repository,
        spindle: spindle,
        workflows: workflow,
        json: json
      )
    }
  }
}
