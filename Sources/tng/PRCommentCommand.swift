import ArgumentParser

struct PRCommentCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "comment",
    abstract: "Comment on a Tangled pull request"
  )

  @Argument(help: "Pull request AT URI")
  var pullRequestURI: String

  @Option(help: "Comment body")
  var body: String?

  @Option(help: "Read the comment body from a file")
  var bodyFile: String?

  @Option(help: "Pull request round index (defaults to the latest round)")
  var round: Int?

  @Flag(help: "Output the created comment record as JSON")
  var json = false

  mutating func validate() throws {
    guard (body != nil) != (bodyFile != nil) else {
      throw ValidationError("Specify exactly one of --body or --body-file")
    }
    if let round, round < 0 {
      throw ValidationError("--round must not be negative")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PRCommandService(formatter: .live).comment(
        pullRequestURI: pullRequestURI,
        body: body,
        bodyFile: bodyFile,
        roundNumber: round,
        json: json
      )
    }
  }
}
