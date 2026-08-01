import ArgumentParser
import SwiftTangled

struct RepoCollaboratorListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List repository collaborators from its Knot"
  )

  @Argument(help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)")
  var repository: String?

  @Option(name: [.customShort("L"), .long], help: "Maximum number of collaborators to return")
  var limit = 30

  @Option(help: "Knot cursor from a previous response")
  var cursor: String?

  @Option(
    help: "Sort by creation time: asc or desc",
    completion: .list(CLICompletionValues.sortOrders)
  )
  var sort = BobbinSortOrder.descending.rawValue

  @Flag(help: "Output the complete page as JSON")
  var json = false

  mutating func validate() throws {
    guard (1 ... 1_000).contains(limit) else {
      throw ValidationError("--limit must be between 1 and 1000")
    }
    guard BobbinSortOrder(rawValue: sort) != nil else {
      throw ValidationError("--sort must be asc or desc")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await RepoCollaboratorCommandService(formatter: .live).list(
        repository: repository,
        cursor: cursor,
        limit: limit,
        sort: BobbinSortOrder(rawValue: sort)!,
        json: json
      )
    }
  }
}
