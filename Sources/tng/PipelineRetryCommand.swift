import ArgumentParser
import Foundation

struct PipelineRetryCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "retry",
    abstract: "Retry a Tangled CI pipeline"
  )

  @Argument(help: "Spindle-local pipeline TID")
  var pipelineID: String

  @Option(
    name: .customLong("repo"),
    help: "Repository reference used to locate its Spindle (defaults to Git origin)"
  )
  var repository: String?

  @Option(help: "Spindle hostname or URL; overrides repository discovery")
  var spindle: String?

  @Option(help: "Retry only the named workflow")
  var workflow: String?

  @Flag(help: "Output the new pipeline AT URI as JSON")
  var json = false

  mutating func validate() throws {
    if let spindle, spindle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ValidationError("--spindle must not be empty")
    }
    if let workflow, workflow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ValidationError("--workflow must not be empty")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PipelineCommandService(formatter: .live).retry(
        pipelineID: pipelineID,
        repository: repository,
        spindle: spindle,
        workflow: workflow,
        json: json
      )
    }
  }
}
