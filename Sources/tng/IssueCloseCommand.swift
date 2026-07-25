import ArgumentParser

struct IssueCloseCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "Close a Tangled issue"
  )

  @Argument(help: "Issue AT URI")
  var issueURI: String

  @Flag(help: "Output the created state record as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await IssueCommandService(formatter: .live).setState(
        issueURI: issueURI,
        state: .closed,
        json: json
      )
    }
  }
}
