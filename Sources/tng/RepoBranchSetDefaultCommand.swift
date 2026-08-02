import ArgumentParser

struct RepoBranchSetDefaultCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set-default",
    abstract: "Set the default branch for a repository"
  )

  @Argument(help: "Existing branch to make the repository default")
  var branch: String

  @Argument(
    help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)"
  )
  var repository: String?

  @Flag(help: "Output a versioned default branch change result as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoCommandService(formatter: .live).setDefaultBranch(
        branch: branch,
        repository: repository,
        json: json
      )
    }
  }
}
