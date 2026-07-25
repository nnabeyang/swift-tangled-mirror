import Foundation
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
  public func comments(
    subjectURI: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<Comment>> {
    try requireNonempty(subjectURI, name: "comment subject URI")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await FeedListComments(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.FeedListComments_Order(rawValue: order.rawValue),
        subject: FormatString<ATURI>(rawValue: subjectURI)
      )
    }
    let items = try response.items.map {
      let record: BobbinRecord<WireComment> = try generatedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value
      )
      return record.commentRecord
    }
    return Page(items: items, cursor: response.cursor)
  }

  public func comments(
    authorDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<Comment>> {
    try requireNonempty(authorDID, name: "comment author DID")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await FeedListCommentsBy(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.FeedListCommentsBy_Order(rawValue: order.rawValue),
        subject: FormatString<DID>(rawValue: authorDID)
      )
    }
    let items = try response.items.map {
      let record: BobbinRecord<WireComment> = try generatedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value
      )
      return record.commentRecord
    }
    return Page(items: items, cursor: response.cursor)
  }

  public func commentCount(subjectURI: String) async throws -> CountSummary {
    try requireNonempty(subjectURI, name: "comment subject URI")
    let response = try await generatedQuery {
      try await FeedCountComments(subject: FormatString<ATURI>(rawValue: subjectURI))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func commentCount(authorDID: String) async throws -> CountSummary {
    try requireNonempty(authorDID, name: "comment author DID")
    let response = try await generatedQuery {
      try await FeedCountCommentsBy(subject: FormatString<DID>(rawValue: authorDID))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func reactions(
    subjectURI: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<Reaction>> {
    try requireNonempty(subjectURI, name: "reaction subject URI")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await FeedListReactions(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.FeedListReactions_Order(rawValue: order.rawValue),
        subject: FormatString<ATURI>(rawValue: subjectURI)
      )
    }
    let items = try response.items.map {
      let record: BobbinRecord<WireReaction> = try generatedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value
      )
      return record.reactionRecord
    }
    return Page(items: items, cursor: response.cursor)
  }

  public func reactions(
    authorDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<Reaction>> {
    try requireNonempty(authorDID, name: "reaction author DID")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await FeedListReactionsBy(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.FeedListReactionsBy_Order(rawValue: order.rawValue),
        subject: FormatString<DID>(rawValue: authorDID)
      )
    }
    let items = try response.items.map {
      let record: BobbinRecord<WireReaction> = try generatedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value
      )
      return record.reactionRecord
    }
    return Page(items: items, cursor: response.cursor)
  }

  public func reactionCount(subjectURI: String) async throws -> CountSummary {
    try requireNonempty(subjectURI, name: "reaction subject URI")
    let response = try await generatedQuery {
      try await FeedCountReactions(subject: FormatString<ATURI>(rawValue: subjectURI))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func reactionCount(authorDID: String) async throws -> CountSummary {
    try requireNonempty(authorDID, name: "reaction author DID")
    let response = try await generatedQuery {
      try await FeedCountReactionsBy(subject: FormatString<DID>(rawValue: authorDID))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }
}

private struct WireComment: Decodable, Sendable {
  let subject: WireRecordReference
  let body: WireMarkdownContent
  let createdAt: FormatString<Date>
  let replyTo: WireRecordReference?
  let pullRoundIdx: Int?
}

private struct WireRecordReference: Decodable, Sendable {
  let uri: String
  let cid: String
}

private struct WireMarkdownContent: Decodable, Sendable {
  let text: String
  let original: String?
  let blobs: [WireBlobReference]?
}

private struct WireBlobReference: Decodable, Sendable {
  let ref: BobbinWireLink
  let mimeType: String
  let size: Int
}

private struct WireReaction: Decodable, Sendable {
  let subject: String
  let reaction: String
  let createdAt: FormatString<Date>
}

extension BobbinRecord where Value == WireComment {
  fileprivate var commentRecord: TangledRecord<Comment> {
    TangledRecord(
      uri: uri,
      cid: cid,
      value: Comment(
        context: CommentContext(
          subject: value.subject.recordReference,
          replyTo: value.replyTo?.recordReference,
          pullRequestRoundIndex: value.pullRoundIdx
        ),
        body: value.body.markdownContent,
        createdAt: value.createdAt
      )
    )
  }
}

extension BobbinRecord where Value == WireReaction {
  fileprivate var reactionRecord: TangledRecord<Reaction> {
    TangledRecord(
      uri: uri,
      cid: cid,
      value: Reaction(
        subjectURI: value.subject,
        value: ReactionValue(rawValue: value.reaction),
        createdAt: value.createdAt
      )
    )
  }
}

extension WireRecordReference {
  fileprivate var recordReference: RecordReference {
    RecordReference(uri: uri, cid: cid)
  }
}

extension WireMarkdownContent {
  fileprivate var markdownContent: MarkdownContent {
    MarkdownContent(
      text: text,
      original: original,
      blobs: (blobs ?? []).map {
        BlobReference(cid: $0.ref.cid, mimeType: $0.mimeType, size: $0.size)
      }
    )
  }
}
