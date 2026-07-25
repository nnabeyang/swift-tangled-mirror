import ArgumentParser

struct SearchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "search",
    abstract: "Search public Tangled records"
  )

  @Argument(help: "Search query")
  var query: String

  @Option(help: "Only include records in this NSID collection")
  var nsid: String?

  @Option(help: "Only include records created by this DID or ATProto handle")
  var author: String?

  @Option(
    help: "Only include records associated with this repository reference"
  )
  var repository: String?

  @Option(help: "Only include records created at or after this AT Protocol datetime")
  var since: String?

  @Option(help: "Only include records created at or before this AT Protocol datetime")
  var until: String?

  @Option(name: [.customShort("L"), .long], help: "Maximum number of results to return")
  var limit = 30

  @Option(help: "Bobbin cursor from a previous response")
  var cursor: String?

  @Flag(help: "Output the complete page as JSON")
  var json = false

  mutating func validate() throws {
    guard (1 ... 1_000).contains(limit) else {
      throw ValidationError("--limit must be between 1 and 1000")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await SearchCommandService(formatter: .live).search(
        query: query,
        nsid: nsid,
        author: author,
        repository: repository,
        since: since,
        until: until,
        limit: limit,
        cursor: cursor,
        json: json
      )
    }
  }
}
