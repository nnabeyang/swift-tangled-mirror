import SwiftTangled

enum CLICompletionValues {
  static let issueStatuses = [
    IssueStatus.open.rawValue,
    IssueStatus.closed.rawValue,
  ]

  static let pullRequestStatuses = [
    PullRequestStatus.open.rawValue,
    PullRequestStatus.closed.rawValue,
    PullRequestStatus.merged.rawValue,
  ]

  static let sortOrders = [
    BobbinSortOrder.ascending.rawValue,
    BobbinSortOrder.descending.rawValue,
  ]
}
