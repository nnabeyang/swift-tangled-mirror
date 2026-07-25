import ArgumentParser

struct PipelineListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List CI pipelines for a Tangled repository"
  )

  @Argument(
    help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)"
  )
  var repository: String?

  @Option(name: [.customShort("L"), .long], help: "Maximum number of pipelines to return")
  var limit = 30

  @Option(help: "Spindle cursor from a previous response")
  var cursor: String?

  @Flag(help: "Output the complete page as JSON")
  var json = false

  mutating func validate() throws {
    guard (1 ... 250).contains(limit) else {
      throw ValidationError("--limit must be between 1 and 250")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PipelineCommandService(formatter: .live).list(
        repository: repository,
        limit: limit,
        cursor: cursor,
        json: json
      )
    }
  }
}
