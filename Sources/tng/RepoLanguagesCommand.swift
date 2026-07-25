import ArgumentParser

struct RepoLanguagesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "languages",
    abstract: "Show language statistics for a repository"
  )

  @Argument(
    help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)"
  )
  var repository: String?

  @Option(help: "Git branch, tag, or commit (defaults to the repository default branch)")
  var ref: String?

  @Flag(help: "Output the complete language report as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoCommandService(formatter: .live).languages(
        repository: repository,
        ref: ref,
        json: json
      )
    }
  }
}
