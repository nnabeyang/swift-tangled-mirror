import Foundation

public struct PullRequestMergeConflict: Codable, Equatable, Hashable, Sendable {
  public let filename: String
  public let reason: String

  public init(filename: String, reason: String) {
    self.filename = filename
    self.reason = reason
  }
}

public struct PullRequestMergeCheck: Codable, Equatable, Hashable, Sendable {
  public let pullRequestURIs: [String]
  public let repositoryDID: String
  public let targetBranch: String
  public let isConflicted: Bool
  public let conflicts: [PullRequestMergeConflict]
  public let message: String?
  public let error: String?
  public let canMerge: Bool

  public init(
    pullRequestURIs: [String],
    repositoryDID: String,
    targetBranch: String,
    isConflicted: Bool,
    conflicts: [PullRequestMergeConflict] = [],
    message: String? = nil,
    error: String? = nil
  ) {
    self.pullRequestURIs = pullRequestURIs
    self.repositoryDID = repositoryDID
    self.targetBranch = targetBranch
    self.isConflicted = isConflicted
    self.conflicts = conflicts
    self.message = message
    self.error = error
    self.canMerge = !isConflicted && error == nil
  }
}

public enum PullRequestMergeOutcome: String, Codable, Equatable, Sendable {
  case merged
  case mergedStatusRecordsFailed = "merged_status_records_failed"
}

public struct PullRequestMergeResult: Codable, Equatable, Sendable {
  public let check: PullRequestMergeCheck
  public let statusRecords: [TangledRecord<PullRequestStatusChange>]
  public let outcome: PullRequestMergeOutcome
  public let statusRecordError: String?

  public init(
    check: PullRequestMergeCheck,
    statusRecords: [TangledRecord<PullRequestStatusChange>],
    outcome: PullRequestMergeOutcome = .merged,
    statusRecordError: String? = nil
  ) {
    self.check = check
    self.statusRecords = statusRecords
    self.outcome = outcome
    self.statusRecordError = statusRecordError
  }
}
