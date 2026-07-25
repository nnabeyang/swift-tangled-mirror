import ArgumentParser

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

  @Flag(help: "Output the workflow statuses as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PipelineCommandService(formatter: .live).status(
        pipelineID: pipelineID,
        repository: repository,
        json: json
      )
    }
  }
}
