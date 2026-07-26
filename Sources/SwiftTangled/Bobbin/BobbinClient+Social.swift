import Foundation
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
  public func stars(
    repositoryDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<Star>> {
    try requireNonempty(repositoryDID, name: "repository DID")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await FeedListStars(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.FeedListStars_Order(rawValue: order.rawValue),
        subject: repositoryDID
      )
    }
    return Page(
      items: try response.items.map(starRecord),
      cursor: response.cursor
    )
  }

  public func stars(
    authorDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<Star>> {
    try requireNonempty(authorDID, name: "star author DID")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await FeedListStarsBy(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.FeedListStarsBy_Order(rawValue: order.rawValue),
        subject: FormatString<DID>(rawValue: authorDID)
      )
    }
    return Page(
      items: try response.items.map(starRecord),
      cursor: response.cursor
    )
  }

  public func starCount(repositoryDID: String) async throws -> CountSummary {
    try requireNonempty(repositoryDID, name: "repository DID")
    let response = try await generatedQuery {
      try await FeedCountStars(subject: repositoryDID)
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func starCount(authorDID: String) async throws -> CountSummary {
    try requireNonempty(authorDID, name: "star author DID")
    let response = try await generatedQuery {
      try await FeedCountStarsBy(subject: FormatString<DID>(rawValue: authorDID))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func followers(
    actorDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<Follow>> {
    try requireNonempty(actorDID, name: "follow subject DID")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await GraphListFollows(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.GraphListFollows_Order(rawValue: order.rawValue),
        subject: FormatString<DID>(rawValue: actorDID)
      )
    }
    return Page(
      items: try response.items.map(followRecord),
      cursor: response.cursor
    )
  }

  public func following(
    actorDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<Follow>> {
    try requireNonempty(actorDID, name: "follow author DID")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await GraphListFollowsBy(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.GraphListFollowsBy_Order(rawValue: order.rawValue),
        subject: FormatString<DID>(rawValue: actorDID)
      )
    }
    return Page(
      items: try response.items.map(followRecord),
      cursor: response.cursor
    )
  }

  public func followerCount(actorDID: String) async throws -> CountSummary {
    try requireNonempty(actorDID, name: "follow subject DID")
    let response = try await generatedQuery {
      try await GraphCountFollows(subject: FormatString<DID>(rawValue: actorDID))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func followingCount(actorDID: String) async throws -> CountSummary {
    try requireNonempty(actorDID, name: "follow author DID")
    let response = try await generatedQuery {
      try await GraphCountFollowsBy(subject: FormatString<DID>(rawValue: actorDID))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }
}

private extension BobbinClient {
  func starRecord(_ item: Sh.Tangled.FeedListStars_ListItem) throws -> TangledRecord<Star> {
    let record: BobbinRecord<Sh.Tangled.FeedStar> = try generatedRecord(
      uri: item.uri,
      cid: item.cid,
      value: item.value
    )
    return TangledRecord(
      uri: record.uri,
      cid: record.cid,
      value: Star(subject: try record.value.subject.starSubject, createdAt: record.value.createdAt)
    )
  }

  func followRecord(
    _ item: Sh.Tangled.GraphListFollows_ListItem
  ) throws -> TangledRecord<Follow> {
    let record: BobbinRecord<Sh.Tangled.GraphFollow> = try generatedRecord(
      uri: item.uri,
      cid: item.cid,
      value: item.value
    )
    return TangledRecord(
      uri: record.uri,
      cid: record.cid,
      value: Follow(subjectDID: record.value.subject.rawValue, createdAt: record.value.createdAt)
    )
  }
}

private extension Sh.Tangled.FeedStar_Subject {
  var starSubject: StarSubject {
    get throws {
      switch self {
      case .feedStarRepo(let value):
        return .repository(did: value.did.rawValue)
      case .feedStarString(let value):
        return .string(uri: value.uri.rawValue)
      case ._other:
        throw TangledError.decoding(UnsupportedStarSubjectError())
      }
    }
  }
}

private struct UnsupportedStarSubjectError: Error {}
