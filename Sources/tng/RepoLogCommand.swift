import ArgumentParser

struct RepoLogCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "log",
    abstract: "List commits in a repository"
  )

  @Argument(
    help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)"
  )
  var repository: String?

  @Option(help: "Git branch, tag, or commit (defaults to the repository default branch)")
  var ref: String?

  @Option(help: "Only include commits affecting this path")
  var path: String?

  @Option(name: [.customShort("L"), .long], help: "Maximum number of commits to return")
  var limit = 30

  @Option(help: "Offset cursor from a previous response")
  var cursor: String?

  @Flag(help: "Output the complete log page as JSON")
  var json = false

  mutating func validate() throws {
    guard (1 ... 100).contains(limit) else {
      throw ValidationError("--limit must be between 1 and 100")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoCommandService(formatter: .live).log(
        repository: repository,
        ref: ref,
        path: path,
        cursor: cursor,
        limit: limit,
        json: json
      )
    }
  }
}
