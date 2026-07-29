import ArgumentParser

struct PipelineCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pipeline",
    abstract: "View Tangled CI pipelines",
    subcommands: [
      PipelineListCommand.self,
      PipelineViewCommand.self,
      PipelineStatusCommand.self,
      PipelineWatchCommand.self,
      PipelineRetryCommand.self,
    ]
  )
}
