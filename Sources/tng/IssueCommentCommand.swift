import ArgumentParser

struct IssueCommentCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "comment",
    abstract: "Comment on a Tangled issue"
  )

  @Argument(help: "Issue AT URI")
  var issueURI: String

  @Option(help: "Comment body")
  var body: String?

  @Option(help: "Read the comment body from a file")
  var bodyFile: String?

  @Flag(help: "Output the created comment record as JSON")
  var json = false

  mutating func validate() throws {
    guard (body != nil) != (bodyFile != nil) else {
      throw ValidationError("Specify exactly one of --body or --body-file")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await IssueCommandService(formatter: .live).comment(
        issueURI: issueURI,
        body: body,
        bodyFile: bodyFile,
        json: json
      )
    }
  }
}
