import ArgumentParser
import SwiftTangled

struct PRListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List pull requests for a Tangled repository"
  )

  @Argument(
    help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)"
  )
  var repository: String?

  @Option(help: "Only include pull requests created by this DID or ATProto handle")
  var author: String?

  @Option(
    help: "Only include pull requests whose status is open, closed, or merged",
    completion: .list(CLICompletionValues.pullRequestStatuses)
  )
  var status: String?

  @Option(name: [.customShort("L"), .long], help: "Maximum number of pull requests to return")
  var limit = 30

  @Option(help: "Pagination cursor from a previous response")
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
    if let status,
      status != PullRequestStatus.open.rawValue,
      status != PullRequestStatus.closed.rawValue,
      status != PullRequestStatus.merged.rawValue
    {
      throw ValidationError("--status must be open, closed, or merged")
    }
    guard BobbinSortOrder(rawValue: sort) != nil else {
      throw ValidationError("--sort must be asc or desc")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await PRCommandService(formatter: .live).list(
        repository: repository,
        author: author,
        status: status.map(PullRequestStatus.init(rawValue:)),
        limit: limit,
        cursor: cursor,
        sort: BobbinSortOrder(rawValue: sort)!,
        json: json
      )
    }
  }
}
