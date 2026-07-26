import Foundation
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
  public func pullRequest(uri: String) async throws -> TangledRecord<PullRequest> {
    try requireNonempty(uri, name: "pull request URI")
    let response = try await generatedQuery {
      try await RepoGetPull(pull: FormatString<ATURI>(rawValue: uri))
    }
    return try TangledRecordDecoder.pullRequest(
      uri: response.uri.rawValue,
      cid: response.cid?.rawValue,
      value: response.value
    )
  }

  public func pullRequests(uris: [String]) async throws -> [TangledRecord<PullRequest>] {
    guard !uris.isEmpty else { return [] }
    try validateBatch(uris, name: "pull request URIs")
    let response = try await generatedQuery {
      try await RepoGetPulls(pulls: uris.map { FormatString<ATURI>(rawValue: $0) })
    }
    return try response.items.map {
      try TangledRecordDecoder.pullRequest(
        uri: $0.uri.rawValue,
        cid: $0.cid?.rawValue,
        value: $0.value
      )
    }
  }

  public func pullRequests(
    repositoryDID: String,
    authorDID: String? = nil,
    status: PullRequestStatus? = nil,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<PullRequestListItem> {
    try requireNonempty(repositoryDID, name: "repository DID")
    if let authorDID {
      try requireNonempty(authorDID, name: "author DID")
    }
    try validatePullRequestStatus(status)
    try validateLimit(limit)

    let response = try await generatedQuery {
      try await RepoListPulls(
        author: authorDID.map { FormatString<DID>(rawValue: $0) },
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.RepoListPulls_Order(rawValue: order.rawValue),
        status: status.map { Sh.Tangled.RepoListPulls_Status(rawValue: $0.rawValue) },
        subject: FormatString<DID>(rawValue: repositoryDID)
      )
    }
    return Page(
      items: try response.items.map {
        try pullRequestListItem(
          uri: $0.uri,
          cid: $0.cid,
          value: $0.value,
          state: $0.state.rawValue,
          stateUpdatedAt: $0.stateUpdatedAt,
          commentCount: $0.commentCount
        )
      },
      cursor: response.cursor
    )
  }

  public func pullRequests(
    authorDID: String,
    status: PullRequestStatus? = nil,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<PullRequestListItem> {
    try requireNonempty(authorDID, name: "author DID")
    try validatePullRequestStatus(status)
    try validateLimit(limit)

    let response = try await generatedQuery {
      try await RepoListPullsBy(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.RepoListPullsBy_Order(rawValue: order.rawValue),
        status: status.map { Sh.Tangled.RepoListPullsBy_Status(rawValue: $0.rawValue) },
        subject: FormatString<DID>(rawValue: authorDID)
      )
    }
    return Page(
      items: try response.items.map {
        try pullRequestListItem(
          uri: $0.uri,
          cid: $0.cid,
          value: $0.value,
          state: $0.state.rawValue,
          stateUpdatedAt: $0.stateUpdatedAt,
          commentCount: $0.commentCount
        )
      },
      cursor: response.cursor
    )
  }

  public func pullRequestCount(repositoryDID: String) async throws -> CountSummary {
    try requireNonempty(repositoryDID, name: "repository DID")
    let response = try await generatedQuery {
      try await RepoCountPulls(subject: FormatString<DID>(rawValue: repositoryDID))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func pullRequestCount(authorDID: String) async throws -> CountSummary {
    try requireNonempty(authorDID, name: "author DID")
    let response = try await generatedQuery {
      try await RepoCountPullsBy(subject: FormatString<DID>(rawValue: authorDID))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func pullRequestStatuses(
    pullRequestURI: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<PullRequestStatusChange>> {
    try requireNonempty(pullRequestURI, name: "pull request URI")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await PullListStatuses(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.Repo.PullListStatuses_Order(rawValue: order.rawValue),
        subject: FormatString<ATURI>(rawValue: pullRequestURI)
      )
    }
    let items = try response.items.map {
      let record: BobbinRecord<Sh.Tangled.Repo.PullStatus> = try generatedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value
      )
      return record.pullRequestStatusRecord
    }
    return Page(items: items, cursor: response.cursor)
  }

  public func pullRequestStatuses(
    authorDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<PullRequestStatusChange>> {
    try requireNonempty(authorDID, name: "author DID")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await PullListStatusesBy(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.Repo.PullListStatusesBy_Order(rawValue: order.rawValue),
        subject: FormatString<DID>(rawValue: authorDID)
      )
    }
    let items = try response.items.map {
      let record: BobbinRecord<Sh.Tangled.Repo.PullStatus> = try generatedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value
      )
      return record.pullRequestStatusRecord
    }
    return Page(items: items, cursor: response.cursor)
  }

  public func pullRequestStatusCount(pullRequestURI: String) async throws -> CountSummary {
    try requireNonempty(pullRequestURI, name: "pull request URI")
    let response = try await generatedQuery {
      try await PullCountStatuses(subject: FormatString<ATURI>(rawValue: pullRequestURI))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func pullRequestStatusCount(authorDID: String) async throws -> CountSummary {
    try requireNonempty(authorDID, name: "author DID")
    let response = try await generatedQuery {
      try await PullCountStatusesBy(subject: FormatString<DID>(rawValue: authorDID))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }
}

extension BobbinClient {
  fileprivate func validatePullRequestStatus(_ status: PullRequestStatus?) throws {
    guard let status else { return }
    try requireNonempty(status.rawValue, name: "pull request status")
  }

  fileprivate func pullRequestListItem(
    uri: FormatString<ATURI>,
    cid: FormatString<LexLink>?,
    value: UnknownATPValue,
    state: String,
    stateUpdatedAt: FormatString<Date>?,
    commentCount: Int
  ) throws -> PullRequestListItem {
    let record = try TangledRecordDecoder.pullRequest(
      uri: uri.rawValue,
      cid: cid?.rawValue,
      value: value
    )
    return PullRequestListItem(
      record: record,
      status: PullRequestStatus(wireValue: state),
      statusUpdatedAt: stateUpdatedAt,
      commentCount: commentCount
    )
  }
}

extension BobbinRecord where Value == Sh.Tangled.Repo.PullStatus {
  fileprivate var pullRequestStatusRecord: TangledRecord<PullRequestStatusChange> {
    TangledRecord(
      uri: uri,
      cid: cid,
      value: PullRequestStatusChange(
        pullRequestURI: value.pull.rawValue,
        status: PullRequestStatus(wireValue: value.status.rawValue),
        createdAt: value.createdAt
      )
    )
  }
}
