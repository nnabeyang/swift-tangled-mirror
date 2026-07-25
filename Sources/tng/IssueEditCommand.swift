import ArgumentParser

struct IssueEditCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit",
    abstract: "Edit a Tangled issue"
  )

  @Argument(help: "Issue AT URI")
  var issueURI: String

  @Option(help: "New issue title")
  var title: String?

  @Option(help: "New issue body (pass an empty value to clear it)")
  var body: String?

  @Option(help: "Read the new issue body from a file")
  var bodyFile: String?

  @Flag(help: "Output the updated issue record as JSON")
  var json = false

  mutating func validate() throws {
    guard title != nil || body != nil || bodyFile != nil else {
      throw ValidationError("Specify at least one of --title, --body, or --body-file")
    }
    guard body == nil || bodyFile == nil else {
      throw ValidationError("Specify at most one of --body or --body-file")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await IssueCommandService(formatter: .live).edit(
        issueURI: issueURI,
        title: title,
        body: body,
        bodyFile: bodyFile,
        json: json
      )
    }
  }
}
