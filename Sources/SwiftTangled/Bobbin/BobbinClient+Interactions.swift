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
    let items = response.items.compactMap {
      tolerantGeneratedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value,
        as: Sh.Tangled.FeedComment.self,
        transform: { try $0.commentRecord }
      )
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
    let items = response.items.compactMap {
      tolerantGeneratedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value,
        as: Sh.Tangled.FeedComment.self,
        transform: { try $0.commentRecord }
      )
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
    let items = response.items.compactMap {
      tolerantGeneratedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value,
        as: Sh.Tangled.FeedReaction.self,
        transform: \.reactionRecord
      )
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
    let items = response.items.compactMap {
      tolerantGeneratedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value,
        as: Sh.Tangled.FeedReaction.self,
        transform: \.reactionRecord
      )
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

extension BobbinRecord where Value == Sh.Tangled.FeedComment {
  fileprivate var commentRecord: TangledRecord<Comment> {
    get throws {
      guard case .markupMarkdown(let body) = value.body else {
        throw TangledError.upstreamFailed("unsupported comment body")
      }
      return TangledRecord(
        uri: uri,
        cid: cid,
        value: Comment(
          context: CommentContext(
            subject: value.subject.recordReference,
            replyTo: value.replyTo?.recordReference,
            pullRequestRoundIndex: value.pullRoundIdx
          ),
          body: body.markdownContent,
          createdAt: value.createdAt
        )
      )
    }
  }
}

extension BobbinRecord where Value == Sh.Tangled.FeedReaction {
  fileprivate var reactionRecord: TangledRecord<Reaction> {
    TangledRecord(
      uri: uri,
      cid: cid,
      value: Reaction(
        subjectURI: value.subject.rawValue,
        value: ReactionValue(rawValue: value.reaction.rawValue),
        createdAt: value.createdAt
      )
    )
  }
}

extension Com.Atproto.RepoStrongRef {
  fileprivate var recordReference: RecordReference {
    RecordReference(uri: uri.rawValue, cid: cid.rawValue)
  }
}

extension Sh.Tangled.MarkupMarkdown {
  fileprivate var markdownContent: MarkdownContent {
    MarkdownContent(
      text: text,
      original: original,
      blobs: (blobs ?? []).map {
        BlobReference(
          cid: $0.ref.toBaseEncodedString,
          mimeType: $0.mimeType,
          size: Int($0.size)
        )
      }
    )
  }
}
