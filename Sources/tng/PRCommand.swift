import ArgumentParser

struct PRCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pr",
    abstract: "View Tangled pull requests",
    subcommands: [
      PRListCommand.self, PRViewCommand.self, PRDiffCommand.self, PRCreateCommand.self,
      PRCommentCommand.self, PRCloseCommand.self, PRReopenCommand.self, PRMergeCommand.self,
    ]
  )
}
