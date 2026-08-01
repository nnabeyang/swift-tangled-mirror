import ArgumentParser

struct RepoSecretRemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Remove a CI secret from a repository"
  )

  @Argument(help: "Repository AT URI, repo DID, handle/name, or clone URL")
  var repository: String

  @Argument(help: "Secret key")
  var key: String

  @Option(help: "Spindle hostname or URL; overrides repository discovery")
  var spindle: String?

  @Flag(help: "Remove without an interactive confirmation")
  var yes = false

  @Flag(help: "Output a versioned secret mutation result as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoSecretCommandService(formatter: .live).remove(
        repository: repository,
        spindle: spindle,
        key: key,
        confirmed: yes,
        json: json
      )
    }
  }
}
