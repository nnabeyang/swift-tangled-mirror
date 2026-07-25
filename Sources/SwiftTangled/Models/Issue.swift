import Foundation
import SwiftAtproto

public struct Issue: Codable, Equatable, Hashable, Sendable {
  public let repositoryDID: String
  public let title: String
  public let body: String?
  public let createdAt: FormatString<Date>
  public let mentions: [String]
  public let references: [String]

  public init(
    repositoryDID: String,
    title: String,
    body: String? = nil,
    createdAt: FormatString<Date>,
    mentions: [String] = [],
    references: [String] = []
  ) {
    self.repositoryDID = repositoryDID
    self.title = title
    self.body = body
    self.createdAt = createdAt
    self.mentions = mentions
    self.references = references
  }
}

public struct IssueStatus: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let open = IssueStatus(rawValue: "open")
  public static let closed = IssueStatus(rawValue: "closed")

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try String(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try rawValue.encode(to: encoder)
  }
}

public struct IssueState: Codable, Equatable, Hashable, Sendable {
  public let issueURI: String
  public let state: IssueStatus
  public let createdAt: FormatString<Date>

  public init(issueURI: String, state: IssueStatus, createdAt: FormatString<Date>) {
    self.issueURI = issueURI
    self.state = state
    self.createdAt = createdAt
  }
}

public struct IssueListItem: Codable, Equatable, Hashable, Sendable {
  public let record: TangledRecord<Issue>
  public let state: IssueStatus
  public let stateUpdatedAt: FormatString<Date>?
  public let commentCount: Int

  public init(
    record: TangledRecord<Issue>,
    state: IssueStatus,
    stateUpdatedAt: FormatString<Date>? = nil,
    commentCount: Int
  ) {
    self.record = record
    self.state = state
    self.stateUpdatedAt = stateUpdatedAt
    self.commentCount = commentCount
  }
}
