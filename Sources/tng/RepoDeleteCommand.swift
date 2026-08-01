import ArgumentParser

struct RepoDeleteCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "delete",
    abstract: "Delete a repository record and its Knot Git repository"
  )

  @Argument(help: "Repository AT URI, repo DID, handle/name, or clone URL")
  var repository: String

  @Flag(help: "Delete without an interactive confirmation")
  var yes = false

  @Flag(help: "Output a versioned repository deletion result as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoCommandService(formatter: .live).delete(
        repository: repository,
        confirmed: yes,
        json: json
      )
    }
  }
}
