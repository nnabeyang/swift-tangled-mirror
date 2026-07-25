import Foundation
import SwiftAtproto

public struct RecordReference: Codable, Equatable, Hashable, Sendable {
  public let uri: String
  public let cid: String

  public init(uri: String, cid: String) {
    self.uri = uri
    self.cid = cid
  }
}

public struct MarkdownContent: Codable, Equatable, Hashable, Sendable {
  public let text: String
  public let original: String?
  public let blobs: [BlobReference]

  public init(text: String, original: String? = nil, blobs: [BlobReference] = []) {
    self.text = text
    self.original = original
    self.blobs = blobs
  }
}

public struct CommentContext: Codable, Equatable, Hashable, Sendable {
  public let subject: RecordReference
  public let replyTo: RecordReference?
  public let pullRequestRoundIndex: Int?

  public init(
    subject: RecordReference,
    replyTo: RecordReference? = nil,
    pullRequestRoundIndex: Int? = nil
  ) {
    self.subject = subject
    self.replyTo = replyTo
    self.pullRequestRoundIndex = pullRequestRoundIndex
  }
}

public struct Comment: Codable, Equatable, Hashable, Sendable {
  public let context: CommentContext
  public let body: MarkdownContent
  public let createdAt: FormatString<Date>

  public init(
    context: CommentContext,
    body: MarkdownContent,
    createdAt: FormatString<Date>
  ) {
    self.context = context
    self.body = body
    self.createdAt = createdAt
  }
}

public struct ReactionValue: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let thumbsUp = ReactionValue(rawValue: "👍")
  public static let thumbsDown = ReactionValue(rawValue: "👎")
  public static let laugh = ReactionValue(rawValue: "😆")
  public static let celebrate = ReactionValue(rawValue: "🎉")
  public static let confused = ReactionValue(rawValue: "🫤")
  public static let heart = ReactionValue(rawValue: "❤️")
  public static let rocket = ReactionValue(rawValue: "🚀")
  public static let eyes = ReactionValue(rawValue: "👀")

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try String(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try rawValue.encode(to: encoder)
  }
}

public struct Reaction: Codable, Equatable, Hashable, Sendable {
  public let subjectURI: String
  public let value: ReactionValue
  public let createdAt: FormatString<Date>

  public init(
    subjectURI: String,
    value: ReactionValue,
    createdAt: FormatString<Date>
  ) {
    self.subjectURI = subjectURI
    self.value = value
    self.createdAt = createdAt
  }
}
