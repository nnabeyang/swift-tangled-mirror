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

public enum CommentBody: Codable, Equatable, Hashable, Sendable {
  case markdown(MarkdownContent)
  case unknown(type: String, fields: [String: JSONValue])

  public var markdown: MarkdownContent? {
    guard case .markdown(let value) = self else { return nil }
    return value
  }

  public init(from decoder: any Decoder) throws {
    let fields = try [String: JSONValue](from: decoder)
    let type: String?
    if case .string(let value) = fields["$type"] {
      type = value
    } else {
      type = nil
    }
    if type == nil || type == "sh.tangled.markup.markdown" {
      self = .markdown(try MarkdownContent(from: decoder))
    } else {
      var unknownFields = fields
      unknownFields.removeValue(forKey: "$type")
      self = .unknown(type: type!, fields: unknownFields)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .markdown(let value):
      try value.encode(to: encoder)
    case .unknown(let type, var fields):
      fields["$type"] = .string(type)
      try fields.encode(to: encoder)
    }
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
  public let body: CommentBody
  public let createdAt: FormatString<Date>

  public init(
    context: CommentContext,
    body: CommentBody,
    createdAt: FormatString<Date>
  ) {
    self.context = context
    self.body = body
    self.createdAt = createdAt
  }

  public init(
    context: CommentContext,
    body: MarkdownContent,
    createdAt: FormatString<Date>
  ) {
    self.init(context: context, body: .markdown(body), createdAt: createdAt)
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
