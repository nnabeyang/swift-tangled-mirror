import ArgumentParser

struct PRViewCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "view",
    abstract: "View a Tangled pull request"
  )

  @Argument(help: "Pull request AT URI")
  var pullRequestURI: String

  @Flag(help: "Output the complete pull request record as JSON")
  var json = false

  @Flag(help: "Include pull request comments")
  var comments = false

  @Option(help: "Maximum number of comments to include")
  var commentLimit = 30

  @Option(help: "Comment pagination cursor")
  var commentCursor: String?

  mutating func validate() throws {
    guard (1 ... 1000).contains(commentLimit) else {
      throw ValidationError("--comment-limit must be between 1 and 1000")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PRCommandService(formatter: .live).view(
        pullRequestURI: pullRequestURI,
        comments: comments,
        commentLimit: commentLimit,
        commentCursor: commentCursor,
        json: json
      )
    }
  }
}
