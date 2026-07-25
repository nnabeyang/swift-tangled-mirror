import ArgumentParser
import SwiftTangled

struct IssueListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List issues for a Tangled repository"
  )

  @Argument(
    help: "Repository AT URI, repo DID, handle/name, or clone URL (defaults to Git origin)"
  )
  var repository: String?

  @Option(help: "Only include issues created by this DID or ATProto handle")
  var author: String?

  @Option(
    help: "Only include issues whose state is open or closed",
    completion: .list(CLICompletionValues.issueStatuses)
  )
  var state: String?

  @Option(name: [.customShort("L"), .long], help: "Maximum number of issues to return")
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
    if let state, state != IssueStatus.open.rawValue, state != IssueStatus.closed.rawValue {
      throw ValidationError("--state must be open or closed")
    }
    guard BobbinSortOrder(rawValue: sort) != nil else {
      throw ValidationError("--sort must be asc or desc")
    }
  }

  func run() async throws {
    try await runCLICommand(jsonErrors: json) {
      try await IssueCommandService(formatter: .live).list(
        repository: repository,
        author: author,
        state: state.map(IssueStatus.init(rawValue:)),
        limit: limit,
        cursor: cursor,
        sort: BobbinSortOrder(rawValue: sort)!,
        json: json
      )
    }
  }
}
