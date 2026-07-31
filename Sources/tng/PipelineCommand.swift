import ArgumentParser

struct PipelineCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pipeline",
    abstract: "Manage Tangled CI pipelines",
    subcommands: [
      PipelineListCommand.self,
      PipelineViewCommand.self,
      PipelineStatusCommand.self,
      PipelineWatchCommand.self,
      PipelineLogsCommand.self,
      PipelineRetryCommand.self,
      PipelineRunCommand.self,
      PipelineCancelCommand.self,
    ]
  )
}
