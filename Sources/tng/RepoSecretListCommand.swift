import ArgumentParser

struct RepoSecretListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List repository CI secret metadata from its Spindle"
  )

  @Argument(help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)")
  var repository: String?

  @Option(help: "Spindle hostname or URL; overrides repository discovery")
  var spindle: String?

  @Flag(help: "Output secret metadata as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoSecretCommandService(formatter: .live).list(
        repository: repository,
        spindle: spindle,
        json: json
      )
    }
  }
}
