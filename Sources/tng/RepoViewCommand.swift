import ArgumentParser

struct RepoViewCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "view",
    abstract: "View a Tangled repository"
  )

  @Argument(
    help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)"
  )
  var repository: String?

  @Flag(help: "Output the complete repository record as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoCommandService(formatter: .live).view(repository: repository, json: json)
    }
  }
}
