import Foundation
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
  public func pullRequest(uri: String) async throws -> TangledRecord<PullRequest> {
    try requireNonempty(uri, name: "pull request URI")
    let response = try await generatedQuery {
      try await RepoGetPull(pull: FormatString<ATURI>(rawValue: uri))
    }
    let record: BobbinRecord<WirePullRequest> = try generatedRecord(
      uri: response.uri,
      cid: response.cid,
      value: response.value
    )
    return record.pullRequestRecord
  }

  public func pullRequests(uris: [String]) async throws -> [TangledRecord<PullRequest>] {
    guard !uris.isEmpty else { return [] }
    try validateBatch(uris, name: "pull request URIs")
    let response = try await generatedQuery {
      try await RepoGetPulls(pulls: uris.map { FormatString<ATURI>(rawValue: $0) })
    }
    return try response.items.map {
      let record: BobbinRecord<WirePullRequest> = try generatedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value
      )
      return record.pullRequestRecord
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
      let record: BobbinRecord<WirePullRequestStatus> = try generatedRecord(
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
      let record: BobbinRecord<WirePullRequestStatus> = try generatedRecord(
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
    let record: BobbinRecord<WirePullRequest> = try generatedRecord(
      uri: uri,
      cid: cid,
      value: value
    )
    return PullRequestListItem(
      record: record.pullRequestRecord,
      status: PullRequestStatus(wireValue: state),
      statusUpdatedAt: stateUpdatedAt,
      commentCount: commentCount
    )
  }
}

private struct WirePullRequest: Decodable, Sendable {
  let title: String
  let body: String?
  let rounds: [WirePullRequestRound]
  let source: WirePullRequestSource?
  let target: WirePullRequestTarget
  let createdAt: FormatString<Date>
  let mentions: [String]?
  let references: [String]?
  let dependentOn: String?
}

private struct WirePullRequestSource: Decodable, Sendable {
  let branch: String
  let repo: String?
}

private struct WirePullRequestTarget: Decodable, Sendable {
  let branch: String
  let repo: String
}

private struct WirePullRequestRound: Decodable, Sendable {
  let createdAt: FormatString<Date>
  let patchBlob: WirePullRequestBlob
}

private struct WirePullRequestBlob: Decodable, Sendable {
  let ref: BobbinWireLink
  let mimeType: String
  let size: Int
}

private struct WirePullRequestStatus: Decodable, Sendable {
  let pull: String
  let status: String
  let createdAt: FormatString<Date>
}

extension BobbinRecord where Value == WirePullRequest {
  fileprivate var pullRequestRecord: TangledRecord<PullRequest> {
    TangledRecord(uri: uri, cid: cid, value: value.pullRequest)
  }
}

extension BobbinRecord where Value == WirePullRequestStatus {
  fileprivate var pullRequestStatusRecord: TangledRecord<PullRequestStatusChange> {
    TangledRecord(
      uri: uri,
      cid: cid,
      value: PullRequestStatusChange(
        pullRequestURI: value.pull,
        status: PullRequestStatus(wireValue: value.status),
        createdAt: value.createdAt
      )
    )
  }
}

extension WirePullRequest {
  fileprivate var pullRequest: PullRequest {
    PullRequest(
      title: title,
      body: body,
      rounds: rounds.map(\.pullRequestRound),
      source: source.map {
        PullRequestSource(branch: $0.branch, repositoryDID: $0.repo)
      },
      target: PullRequestTarget(branch: target.branch, repositoryDID: target.repo),
      createdAt: createdAt,
      mentions: mentions ?? [],
      references: references ?? [],
      dependentOn: dependentOn
    )
  }
}

extension WirePullRequestRound {
  fileprivate var pullRequestRound: PullRequestRound {
    PullRequestRound(
      createdAt: createdAt,
      patchBlob: BlobReference(
        cid: patchBlob.ref.cid,
        mimeType: patchBlob.mimeType,
        size: patchBlob.size
      )
    )
  }
}

extension PullRequestStatus {
  fileprivate static let openNSID = "sh.tangled.repo.pull.status.open"
  fileprivate static let closedNSID = "sh.tangled.repo.pull.status.closed"
  fileprivate static let mergedNSID = "sh.tangled.repo.pull.status.merged"

  fileprivate init(wireValue: String) {
    switch wireValue {
    case Self.open.rawValue, Self.openNSID:
      self = .open
    case Self.closed.rawValue, Self.closedNSID:
      self = .closed
    case Self.merged.rawValue, Self.mergedNSID:
      self = .merged
    default:
      self.init(rawValue: wireValue)
    }
  }
}
