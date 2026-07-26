import ArgumentParser
import SwiftTangled

struct ArtifactListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List artifacts in a repository"
  )

  @Argument(
    help: "Repository DID, AT URI, handle/name, or clone URL (defaults to Git origin)"
  )
  var repository: String?

  @Option(name: [.customShort("L"), .long], help: "Maximum number of artifacts to return")
  var limit = 30

  @Option(help: "Pagination cursor from a previous response")
  var cursor: String?

  @Option(
    help: "Sort by creation time: asc or desc",
    completion: .list(CLICompletionValues.sortOrders)
  )
  var sort = ArtifactSortOrder.desc.rawValue

  @Flag(help: "Output a versioned artifact page as JSON")
  var json = false

  mutating func validate() throws {
    guard (1 ... 1_000).contains(limit) else {
      throw ValidationError("--limit must be between 1 and 1000")
    }
    guard ArtifactSortOrder(rawValue: sort) != nil else {
      throw ValidationError("--sort must be asc or desc")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await ArtifactCommandService(formatter: .live).list(
        repository: repository,
        limit: limit,
        cursor: cursor,
        sort: ArtifactSortOrder(rawValue: sort)!,
        json: json
      )
    }
  }
}
