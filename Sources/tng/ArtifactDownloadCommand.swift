import ArgumentParser

struct ArtifactDownloadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "download",
    abstract: "Download and verify an artifact"
  )

  @Argument(help: "Remote annotated Git tag name")
  var tag: String

  @Argument(help: "Artifact name")
  var name: String

  @Option(help: "Repository (defaults to Git origin)")
  var repo: String?

  @Option(name: [.customShort("o"), .long], help: "Path to save the artifact")
  var output: String?

  @Flag(help: "Replace an existing regular output file")
  var force = false

  @Flag(help: "Output a versioned download result as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await ArtifactCommandService(formatter: .live).download(
        repository: repo,
        tag: tag,
        name: name,
        output: output,
        force: force,
        json: json
      )
    }
  }
}
