import ArgumentParser

struct RepoUnstarCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "unstar",
    abstract: "Remove a repository from your favorites"
  )

  @Argument(
    help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)"
  )
  var repository: String?

  func run() async throws {
    try await runCLICommand {
      try await RepoCommandService(formatter: .live).unstar(repository: repository)
    }
  }
}
