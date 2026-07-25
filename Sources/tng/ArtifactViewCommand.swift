import ArgumentParser

struct ArtifactViewCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "view",
    abstract: "View artifacts attached to an annotated Git tag"
  )

  @Argument(help: "Remote annotated Git tag name")
  var tag: String

  @Option(help: "Repository (defaults to Git origin)")
  var repo: String?

  @Flag(help: "Output a versioned tag view as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await ArtifactCommandService(formatter: .live).view(
        repository: repo,
        tag: tag,
        json: json
      )
    }
  }
}
