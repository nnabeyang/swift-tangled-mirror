import ArgumentParser

struct RepoBlobCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "blob",
    abstract: "Show a file from a repository"
  )

  @Argument(help: "File path within the repository")
  var path: String

  @Argument(
    help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)"
  )
  var repository: String?

  @Option(help: "Git branch, tag, or commit (defaults to the repository default branch)")
  var ref: String?

  @Flag(help: "Output blob content and metadata as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoCommandService(formatter: .live).blob(
        path: path,
        repository: repository,
        ref: ref,
        json: json
      )
    }
  }
}
