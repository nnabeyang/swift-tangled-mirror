import ArgumentParser

struct RepoTagListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List tags in a repository"
  )

  @Argument(
    help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)"
  )
  var repository: String?

  @Option(name: [.customShort("L"), .long], help: "Maximum number of tags to return")
  var limit = 30

  @Option(help: "Offset cursor from a previous response")
  var cursor: String?

  @Flag(help: "Output the complete tag page as JSON")
  var json = false

  mutating func validate() throws {
    guard (1 ... 100).contains(limit) else {
      throw ValidationError("--limit must be between 1 and 100")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoCommandService(formatter: .live).tags(
        repository: repository,
        cursor: cursor,
        limit: limit,
        json: json
      )
    }
  }
}
