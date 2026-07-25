import ArgumentParser

struct IssueCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "issue",
    abstract: "Work with Tangled issues",
    subcommands: [
      IssueListCommand.self,
      IssueViewCommand.self,
      IssueCreateCommand.self,
      IssueCommentCommand.self,
      IssueEditCommand.self,
      IssueCloseCommand.self,
      IssueReopenCommand.self,
    ]
  )
}
