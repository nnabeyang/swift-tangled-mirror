import Foundation

public struct PullRequestStackCommit: Equatable, Sendable {
  public let title: String
  public let body: String?
  public let changeID: String
  public let patch: Data

  public init(
    title: String,
    body: String? = nil,
    changeID: String,
    patch: Data
  ) {
    self.title = title
    self.body = body
    self.changeID = changeID
    self.patch = patch
  }
}

public struct PullRequestStackCreationResult: Codable, Equatable, Sendable {
  public let pullRequests: [TangledRecord<PullRequest>]

  public init(pullRequests: [TangledRecord<PullRequest>]) {
    self.pullRequests = pullRequests
  }
}
