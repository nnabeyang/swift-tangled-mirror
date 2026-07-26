import Foundation
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
  public func profile(uri: String) async throws -> TangledRecord<Profile> {
    try requireNonempty(uri, name: "profile URI")
    let response = try await generatedQuery {
      try await ActorGetProfile(actor: FormatString<ATURI>(rawValue: uri))
    }
    let record: BobbinRecord<Sh.Tangled.ActorProfile> = try generatedRecord(
      uri: response.uri,
      cid: response.cid,
      value: response.value
    )
    return record.profileRecord
  }

  public func profiles(uris: [String]) async throws -> [TangledRecord<Profile>] {
    guard !uris.isEmpty else { return [] }
    try validateBatch(uris, name: "profile URIs")
    let response = try await generatedQuery {
      try await ActorGetProfiles(actors: uris.map { FormatString<ATURI>(rawValue: $0) })
    }
    return try response.items.map {
      let record: BobbinRecord<Sh.Tangled.ActorProfile> = try generatedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value
      )
      return record.profileRecord
    }
  }

  public func repository(uri: String) async throws -> TangledRecord<Repository> {
    try requireNonempty(uri, name: "repository URI")
    let response = try await generatedQuery {
      try await RepoGetRepo(repo: FormatString<ATURI>(rawValue: uri))
    }
    return try TangledRecordDecoder.repository(
      uri: response.uri.rawValue,
      cid: response.cid?.rawValue,
      value: response.value
    )
  }

  public func repositories(uris: [String]) async throws -> [TangledRecord<Repository>] {
    guard !uris.isEmpty else { return [] }
    try validateBatch(uris, name: "repository URIs")
    let response = try await generatedQuery {
      try await RepoGetRepos(repos: uris.map { FormatString<ATURI>(rawValue: $0) })
    }
    return try response.items.map {
      try TangledRecordDecoder.repository(
        uri: $0.uri.rawValue,
        cid: $0.cid?.rawValue,
        value: $0.value
      )
    }
  }

  public func repository(repoDID: String) async throws -> TangledRecord<Repository> {
    try requireNonempty(repoDID, name: "repository DID")
    let response = try await generatedQuery {
      try await RepoGetRepoByRepoDid(repoDid: FormatString<DID>(rawValue: repoDID))
    }
    return try TangledRecordDecoder.repository(
      uri: response.uri.rawValue,
      cid: response.cid?.rawValue,
      value: response.value
    )
  }

  public func repositories(
    ownerDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<Repository>> {
    try requireNonempty(ownerDID, name: "owner DID")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await RepoListRepos(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.RepoListRepos_Order(rawValue: order.rawValue),
        subject: FormatString<DID>(rawValue: ownerDID)
      )
    }
    let items = try response.items.map {
      try TangledRecordDecoder.repository(
        uri: $0.uri.rawValue,
        cid: $0.cid?.rawValue,
        value: $0.value
      )
    }
    return Page(items: items, cursor: response.cursor)
  }

  public func repositoryCount(ownerDID: String) async throws -> CountSummary {
    try requireNonempty(ownerDID, name: "owner DID")
    let response = try await generatedQuery {
      try await RepoCountRepos(subject: FormatString<DID>(rawValue: ownerDID))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func search(
    _ query: String,
    options: SearchOptions = SearchOptions()
  ) async throws -> Page<SearchHit> {
    try requireNonempty(query, name: "search query")
    try validateLimit(options.limit)
    try options.validateDates()

    let response = try await generatedQuery {
      try await SearchQuery(
        author: options.authorDID.map { FormatString<DID>(rawValue: $0) },
        cursor: options.cursor,
        limit: options.limit,
        nsid: options.nsid.map { FormatString<NSID>(rawValue: $0) },
        q: query,
        repo: options.repoDID.map { FormatString<DID>(rawValue: $0) },
        since: options.since,
        until: options.until
      )
    }
    return Page(
      items: try response.hits.map {
        SearchHit(
          uri: $0.uri.rawValue,
          cid: $0.cid?.rawValue,
          nsid: $0.nsid.rawValue,
          score: try decodeGenerated($0.score, as: Double.self),
          value: try decodeGenerated($0.value, as: JSONValue.self)
        )
      },
      cursor: response.cursor
    )
  }
}

extension BobbinRecord where Value == Sh.Tangled.ActorProfile {
  fileprivate var profileRecord: TangledRecord<Profile> {
    TangledRecord(
      uri: uri,
      cid: cid,
      value: Profile(
        avatar: value.avatar.map {
          BlobReference(
            cid: $0.ref.toBaseEncodedString,
            mimeType: $0.mimeType,
            size: Int($0.size)
          )
        },
        bluesky: value.bluesky,
        description: value.description,
        links: value.links?.map(\.rawValue) ?? [],
        location: value.location,
        pinnedRepositories: value.pinnedRepositories ?? [],
        preferredHandle: value.preferredHandle?.rawValue,
        pronouns: value.pronouns,
        stats: value.stats?.map(\.rawValue) ?? []
      )
    )
  }
}
