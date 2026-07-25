import ArgumentParser
import SwiftTangled

struct RepoListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List repositories owned by a DID or handle"
  )

  @Argument(help: "Owner DID or ATProto handle (defaults to the signed-in account)")
  var owner: String?

  @Option(name: [.customShort("L"), .long], help: "Maximum number of repositories to return")
  var limit = 30

  @Option(help: "Bobbin cursor from a previous response")
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
      try await RepoCommandService(formatter: .live).list(
        owner: owner,
        limit: limit,
        cursor: cursor,
        sort: BobbinSortOrder(rawValue: sort)!,
        json: json
      )
    }
  }
}
