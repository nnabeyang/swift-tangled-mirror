import Foundation
import SwiftAtproto

public struct PullRequestSource: Codable, Equatable, Hashable, Sendable {
  public let branch: String
  public let repositoryDID: String?

  public init(branch: String, repositoryDID: String? = nil) {
    self.branch = branch
    self.repositoryDID = repositoryDID
  }
}

public struct PullRequestTarget: Codable, Equatable, Hashable, Sendable {
  public let branch: String
  public let repositoryDID: String

  public init(branch: String, repositoryDID: String) {
    self.branch = branch
    self.repositoryDID = repositoryDID
  }
}

public struct PullRequestRound: Codable, Equatable, Hashable, Sendable {
  public let createdAt: FormatString<Date>
  public let patchBlob: BlobReference

  public init(createdAt: FormatString<Date>, patchBlob: BlobReference) {
    self.createdAt = createdAt
    self.patchBlob = patchBlob
  }
}

public struct PullRequest: Codable, Equatable, Hashable, Sendable {
  public let title: String
  public let body: String?
  public let rounds: [PullRequestRound]
  public let source: PullRequestSource?
  public let target: PullRequestTarget
  public let createdAt: FormatString<Date>
  public let mentions: [String]
  public let references: [String]
  public let dependentOn: String?

  public init(
    title: String,
    body: String? = nil,
    rounds: [PullRequestRound],
    source: PullRequestSource? = nil,
    target: PullRequestTarget,
    createdAt: FormatString<Date>,
    mentions: [String] = [],
    references: [String] = [],
    dependentOn: String? = nil
  ) {
    self.title = title
    self.body = body
    self.rounds = rounds
    self.source = source
    self.target = target
    self.createdAt = createdAt
    self.mentions = mentions
    self.references = references
    self.dependentOn = dependentOn
  }
}

public struct PullRequestStatus: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let open = PullRequestStatus(rawValue: "open")
  public static let closed = PullRequestStatus(rawValue: "closed")
  public static let merged = PullRequestStatus(rawValue: "merged")

  init(wireValue: String) {
    switch wireValue {
    case Self.open.rawValue, "sh.tangled.repo.pull.status.open":
      self = .open
    case Self.closed.rawValue, "sh.tangled.repo.pull.status.closed":
      self = .closed
    case Self.merged.rawValue, "sh.tangled.repo.pull.status.merged":
      self = .merged
    default:
      self.init(rawValue: wireValue)
    }
  }

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try String(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try rawValue.encode(to: encoder)
  }
}

public struct PullRequestStatusChange: Codable, Equatable, Hashable, Sendable {
  public let pullRequestURI: String
  public let status: PullRequestStatus
  public let createdAt: FormatString<Date>

  public init(
    pullRequestURI: String,
    status: PullRequestStatus,
    createdAt: FormatString<Date>
  ) {
    self.pullRequestURI = pullRequestURI
    self.status = status
    self.createdAt = createdAt
  }
}

public struct PullRequestListItem: Codable, Equatable, Hashable, Sendable {
  public let record: TangledRecord<PullRequest>
  public let status: PullRequestStatus
  public let statusUpdatedAt: FormatString<Date>?
  public let commentCount: Int

  public init(
    record: TangledRecord<PullRequest>,
    status: PullRequestStatus,
    statusUpdatedAt: FormatString<Date>? = nil,
    commentCount: Int
  ) {
    self.record = record
    self.status = status
    self.statusUpdatedAt = statusUpdatedAt
    self.commentCount = commentCount
  }
}
