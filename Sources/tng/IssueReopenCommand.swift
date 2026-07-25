import ArgumentParser

struct IssueReopenCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "reopen",
    abstract: "Reopen a Tangled issue"
  )

  @Argument(help: "Issue AT URI")
  var issueURI: String

  @Flag(help: "Output the created state record as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await IssueCommandService(formatter: .live).setState(
        issueURI: issueURI,
        state: .open,
        json: json
      )
    }
  }
}
