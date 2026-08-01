import ArgumentParser

struct RepoSecretAddCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Add a CI secret to a repository"
  )

  @Argument(help: "Repository AT URI, repo DID, handle/name, or clone URL")
  var repository: String

  @Argument(help: "Secret key")
  var key: String

  @Option(help: "Spindle hostname or URL; overrides repository discovery")
  var spindle: String?

  @Flag(help: "Output a versioned secret mutation result as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoSecretCommandService(formatter: .live).add(
        repository: repository,
        spindle: spindle,
        key: key,
        json: json
      )
    }
  }
}
