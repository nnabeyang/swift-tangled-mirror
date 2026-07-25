import ArgumentParser

struct ArtifactDeleteCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "delete",
    abstract: "Delete an artifact record without deleting its Git tag"
  )

  @Argument(help: "Remote annotated Git tag name")
  var tag: String

  @Argument(help: "Artifact name")
  var name: String

  @Option(help: "Repository (defaults to Git origin)")
  var repo: String?

  @Flag(help: "Delete without an interactive confirmation")
  var yes = false

  @Flag(help: "Output a versioned deleted artifact record as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await ArtifactCommandService(formatter: .live).delete(
        repository: repo,
        tag: tag,
        name: name,
        confirmed: yes,
        json: json
      )
    }
  }
}
