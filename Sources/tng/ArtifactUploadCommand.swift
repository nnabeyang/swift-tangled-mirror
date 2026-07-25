import ArgumentParser

struct ArtifactUploadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "upload",
    abstract: "Upload a file to an annotated Git tag"
  )

  @Argument(help: "Remote annotated Git tag name")
  var tag: String

  @Argument(help: "Local regular file to upload")
  var file: String

  @Option(help: "Repository (defaults to Git origin)")
  var repo: String?

  @Option(help: "Artifact name (defaults to the local file name)")
  var name: String?

  @Option(help: "Artifact media type")
  var contentType = "application/octet-stream"

  @Flag(help: "Replace an artifact record owned by the signed-in account")
  var force = false

  @Flag(help: "Output a versioned artifact record as JSON")
  var json = false

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await ArtifactCommandService(formatter: .live).upload(
        repository: repo,
        tag: tag,
        file: file,
        name: name,
        contentType: contentType,
        force: force,
        json: json
      )
    }
  }
}
