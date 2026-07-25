import Foundation
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
  public func issue(uri: String) async throws -> TangledRecord<Issue> {
    try requireNonempty(uri, name: "issue URI")
    let response = try await generatedQuery {
      try await RepoGetIssue(issue: FormatString<ATURI>(rawValue: uri))
    }
    return try TangledRecordDecoder.issue(
      uri: response.uri.rawValue,
      cid: response.cid?.rawValue,
      value: response.value
    )
  }

  public func issues(uris: [String]) async throws -> [TangledRecord<Issue>] {
    guard !uris.isEmpty else { return [] }
    try validateBatch(uris, name: "issue URIs")
    let response = try await generatedQuery {
      try await RepoGetIssues(issues: uris.map { FormatString<ATURI>(rawValue: $0) })
    }
    return try response.items.map {
      try TangledRecordDecoder.issue(
        uri: $0.uri.rawValue,
        cid: $0.cid?.rawValue,
        value: $0.value
      )
    }
  }

  public func issues(
    repositoryDID: String,
    authorDID: String? = nil,
    state: IssueStatus? = nil,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<IssueListItem> {
    try requireNonempty(repositoryDID, name: "repository DID")
    if let authorDID {
      try requireNonempty(authorDID, name: "author DID")
    }
    try validateIssueState(state)
    try validateLimit(limit)

    let response = try await generatedQuery {
      try await RepoListIssues(
        author: authorDID.map { FormatString<DID>(rawValue: $0) },
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.RepoListIssues_Order(rawValue: order.rawValue),
        state: state.map { Sh.Tangled.RepoListIssues_State(rawValue: $0.rawValue) },
        subject: FormatString<DID>(rawValue: repositoryDID)
      )
    }
    return Page(
      items: try response.items.map {
        try issueListItem(
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

  public func issues(
    authorDID: String,
    state: IssueStatus? = nil,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<IssueListItem> {
    try requireNonempty(authorDID, name: "author DID")
    try validateIssueState(state)
    try validateLimit(limit)

    let response = try await generatedQuery {
      try await RepoListIssuesBy(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.RepoListIssuesBy_Order(rawValue: order.rawValue),
        state: state.map { Sh.Tangled.RepoListIssuesBy_State(rawValue: $0.rawValue) },
        subject: FormatString<DID>(rawValue: authorDID)
      )
    }
    return Page(
      items: try response.items.map {
        try issueListItem(
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

  public func issueCount(repositoryDID: String) async throws -> CountSummary {
    try requireNonempty(repositoryDID, name: "repository DID")
    let response = try await generatedQuery {
      try await RepoCountIssues(subject: FormatString<DID>(rawValue: repositoryDID))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func issueCount(authorDID: String) async throws -> CountSummary {
    try requireNonempty(authorDID, name: "author DID")
    let response = try await generatedQuery {
      try await RepoCountIssuesBy(subject: FormatString<DID>(rawValue: authorDID))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func issueStates(
    issueURI: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<IssueState>> {
    try requireNonempty(issueURI, name: "issue URI")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await IssueListStates(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.Repo.IssueListStates_Order(rawValue: order.rawValue),
        subject: FormatString<ATURI>(rawValue: issueURI)
      )
    }
    let items = try response.items.map {
      let record: BobbinRecord<WireIssueState> = try generatedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value
      )
      return record.issueStateRecord
    }
    return Page(items: items, cursor: response.cursor)
  }

  public func issueStates(
    authorDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<IssueState>> {
    try requireNonempty(authorDID, name: "author DID")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await IssueListStatesBy(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.Repo.IssueListStatesBy_Order(rawValue: order.rawValue),
        subject: FormatString<DID>(rawValue: authorDID)
      )
    }
    let items = try response.items.map {
      let record: BobbinRecord<WireIssueState> = try generatedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value
      )
      return record.issueStateRecord
    }
    return Page(items: items, cursor: response.cursor)
  }

  public func issueStateCount(issueURI: String) async throws -> CountSummary {
    try requireNonempty(issueURI, name: "issue URI")
    let response = try await generatedQuery {
      try await IssueCountStates(subject: FormatString<ATURI>(rawValue: issueURI))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func issueStateCount(authorDID: String) async throws -> CountSummary {
    try requireNonempty(authorDID, name: "author DID")
    let response = try await generatedQuery {
      try await IssueCountStatesBy(subject: FormatString<DID>(rawValue: authorDID))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }
}

extension BobbinClient {
  fileprivate func validateIssueState(_ state: IssueStatus?) throws {
    guard let state else { return }
    try requireNonempty(state.rawValue, name: "issue state")
  }

  fileprivate func issueListItem(
    uri: FormatString<ATURI>,
    cid: FormatString<LexLink>?,
    value: UnknownATPValue,
    state: String,
    stateUpdatedAt: FormatString<Date>?,
    commentCount: Int
  ) throws -> IssueListItem {
    let record = try TangledRecordDecoder.issue(
      uri: uri.rawValue,
      cid: cid?.rawValue,
      value: value
    )
    return IssueListItem(
      record: record,
      state: IssueStatus(wireValue: state),
      stateUpdatedAt: stateUpdatedAt,
      commentCount: commentCount
    )
  }
}

private struct WireIssueState: Decodable, Sendable {
  let issue: String
  let state: String
  let createdAt: FormatString<Date>
}

extension BobbinRecord where Value == WireIssueState {
  fileprivate var issueStateRecord: TangledRecord<IssueState> {
    TangledRecord(
      uri: uri,
      cid: cid,
      value: IssueState(
        issueURI: value.issue,
        state: IssueStatus(wireValue: value.state),
        createdAt: value.createdAt
      )
    )
  }
}

extension IssueStatus {
  fileprivate static let openNSID = "sh.tangled.repo.issue.state.open"
  fileprivate static let closedNSID = "sh.tangled.repo.issue.state.closed"

  fileprivate init(wireValue: String) {
    switch wireValue {
    case Self.open.rawValue, Self.openNSID:
      self = .open
    case Self.closed.rawValue, Self.closedNSID:
      self = .closed
    default:
      self.init(rawValue: wireValue)
    }
  }
}
