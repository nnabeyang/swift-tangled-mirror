import ArgumentParser

struct RepoStarCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "star",
    abstract: "Add a repository to your favorites"
  )

  @Argument(
    help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)"
  )
  var repository: String?

  func run() async throws {
    try await runCLICommand {
      try await RepoCommandService(formatter: .live).star(repository: repository)
    }
  }
}
