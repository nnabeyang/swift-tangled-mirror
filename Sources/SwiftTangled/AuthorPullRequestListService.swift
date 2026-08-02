import Foundation
import SwiftAtproto

public struct AuthorPullRequestListService: Sendable {
  private let loadPullRequests:
    @Sendable (String, String?, Int?, Bool) async throws -> Page<
      TangledRecord<PullRequest>
    >
  private let loadStatuses:
    @Sendable (String, String?, Int?, Bool) async throws -> Page<
      TangledRecord<PullRequestStatusChange>
    >

  public init(pdsRecordClient: PDSRecordClient = PDSRecordClient()) {
    loadPullRequests = {
      try await pdsRecordClient.pullRequests(
        ownerDID: $0,
        cursor: $1,
        limit: $2,
        reverse: $3
      )
    }
    loadStatuses = {
      try await pdsRecordClient.pullRequestStatuses(
        ownerDID: $0,
        cursor: $1,
        limit: $2,
        reverse: $3
      )
    }
  }

  init(
    loadPullRequests:
      @escaping @Sendable (
        String, String?, Int?, Bool
      ) async throws -> Page<TangledRecord<PullRequest>>,
    loadStatuses:
      @escaping @Sendable (
        String, String?, Int?, Bool
      ) async throws -> Page<TangledRecord<PullRequestStatusChange>>
  ) {
    self.loadPullRequests = loadPullRequests
    self.loadStatuses = loadStatuses
  }

  public func list(
    repositoryDID: String,
    repositoryOwnerDID: String,
    authorDID: String,
    status: PullRequestStatus? = nil,
    cursor: String? = nil,
    limit: Int = 30,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<PullRequestListItem> {
    guard (1 ... 1_000).contains(limit) else {
      throw TangledError.invalidRequest("pull request limit must be between 1 and 1000")
    }
    let position =
      try cursor.map {
        try AuthorPullRequestCursor.decode(
          $0,
          repositoryDID: repositoryDID,
          authorDID: authorDID,
          status: status,
          order: order
        )
      }
    async let loadedPulls = allPullRequests(ownerDID: authorDID)
    async let loadedAuthorStatuses = allStatuses(ownerDID: authorDID)
    let ownerStatuses =
      repositoryOwnerDID == authorDID
      ? [] : try await allStatuses(ownerDID: repositoryOwnerDID)
    let pulls = try await loadedPulls
    let authorStatuses = try await loadedAuthorStatuses
    return try AuthorPullRequestPageBuilder.page(
      pulls: pulls,
      statuses: authorStatuses + ownerStatuses,
      repositoryDID: repositoryDID,
      authorDID: authorDID,
      status: status,
      position: position,
      limit: limit,
      order: order
    )
  }

  private func allPullRequests(
    ownerDID: String
  ) async throws -> [TangledRecord<PullRequest>] {
    try await allRecords(ownerDID: ownerDID, load: loadPullRequests)
  }

  private func allStatuses(
    ownerDID: String
  ) async throws -> [TangledRecord<PullRequestStatusChange>] {
    try await allRecords(ownerDID: ownerDID, load: loadStatuses)
  }

  private func allRecords<Value: Sendable>(
    ownerDID: String,
    load: @Sendable (String, String?, Int?, Bool) async throws -> Page<Value>
  ) async throws -> [Value] {
    var records: [Value] = []
    var cursor: String?
    var seenCursors = Set<String>()
    repeat {
      let page = try await load(ownerDID, cursor, 100, false)
      records.append(contentsOf: page.items)
      guard let next = page.cursor else { break }
      guard seenCursors.insert(next).inserted else {
        throw TangledError.upstreamFailed("PDS returned a repeated pagination cursor")
      }
      cursor = next
    } while true
    return records
  }
}

enum AuthorPullRequestPageBuilder {
  static func page(
    pulls: [TangledRecord<PullRequest>],
    statuses: [TangledRecord<PullRequestStatusChange>],
    repositoryDID: String,
    authorDID: String,
    status: PullRequestStatus?,
    position: AuthorPullRequestCursor.Position?,
    limit: Int,
    order: BobbinSortOrder
  ) throws(TangledError) -> Page<PullRequestListItem> {
    let latestStatuses = latestStatusesByPullRequest(statuses)
    var items = pulls.compactMap { pull -> PullRequestListItem? in
      guard pull.value.target.repositoryDID == repositoryDID else { return nil }
      let latest = latestStatuses[pull.uri]
      let derivedStatus = latest?.value.status ?? .open
      guard status == nil || status == derivedStatus else { return nil }
      return PullRequestListItem(
        record: pull,
        status: derivedStatus,
        statusUpdatedAt: latest?.value.createdAt,
        commentCount: -1
      )
    }
    items.sort { precedes($0.record, $1.record, order: order) }
    if let position {
      items.removeAll {
        !follows($0.record, position: position, order: order)
      }
    }
    let pageItems = Array(items.prefix(limit))
    let nextCursor: String?
    if items.count > pageItems.count, let last = pageItems.last {
      nextCursor = try AuthorPullRequestCursor.encode(
        record: last.record,
        repositoryDID: repositoryDID,
        authorDID: authorDID,
        status: status,
        order: order
      )
    } else {
      nextCursor = nil
    }
    return Page(items: pageItems, cursor: nextCursor)
  }

  private static func latestStatusesByPullRequest(
    _ statuses: [TangledRecord<PullRequestStatusChange>]
  ) -> [String: TangledRecord<PullRequestStatusChange>] {
    var result: [String: TangledRecord<PullRequestStatusChange>] = [:]
    for record in statuses {
      let pull = record.value.pullRequestURI
      if let current = result[pull], !statusPrecedes(current, record) {
        continue
      }
      result[pull] = record
    }
    return result
  }

  private static func statusPrecedes(
    _ lhs: TangledRecord<PullRequestStatusChange>,
    _ rhs: TangledRecord<PullRequestStatusChange>
  ) -> Bool {
    dateKey(lhs.value.createdAt, uri: lhs.uri) < dateKey(rhs.value.createdAt, uri: rhs.uri)
  }

  static func precedes(
    _ lhs: TangledRecord<PullRequest>,
    _ rhs: TangledRecord<PullRequest>,
    order: BobbinSortOrder
  ) -> Bool {
    let lhsKey = dateKey(lhs.value.createdAt, uri: lhs.uri)
    let rhsKey = dateKey(rhs.value.createdAt, uri: rhs.uri)
    return order == .ascending ? lhsKey < rhsKey : lhsKey > rhsKey
  }

  static func follows(
    _ record: TangledRecord<PullRequest>,
    position: AuthorPullRequestCursor.Position,
    order: BobbinSortOrder
  ) -> Bool {
    let recordKey = dateKey(record.value.createdAt, uri: record.uri)
    let positionKey = dateKey(position.createdAt, uri: position.uri)
    return order == .ascending ? recordKey > positionKey : recordKey < positionKey
  }

  private static func dateKey(
    _ value: FormatString<Date>,
    uri: String
  ) -> PullRequestDateKey {
    PullRequestDateKey(
      timestamp: value.typed?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude,
      rawValue: value.rawValue,
      uri: uri
    )
  }
}

private struct PullRequestDateKey: Comparable {
  let timestamp: TimeInterval
  let rawValue: String
  let uri: String

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.timestamp != rhs.timestamp {
      return lhs.timestamp < rhs.timestamp
    }
    if lhs.rawValue != rhs.rawValue {
      return lhs.rawValue < rhs.rawValue
    }
    return lhs.uri < rhs.uri
  }
}

enum AuthorPullRequestCursor {
  private static let prefix = "tng-pr-list-v1."

  struct Position: Codable {
    let version: Int
    let repositoryDID: String
    let authorDID: String
    let status: String?
    let order: String
    let createdAt: FormatString<Date>
    let uri: String
  }

  static func encode(
    record: TangledRecord<PullRequest>,
    repositoryDID: String,
    authorDID: String,
    status: PullRequestStatus?,
    order: BobbinSortOrder
  ) throws(TangledError) -> String {
    let data: Data
    do {
      data = try JSONEncoder().encode(
        Position(
          version: 1,
          repositoryDID: repositoryDID,
          authorDID: authorDID,
          status: status?.rawValue,
          order: order.rawValue,
          createdAt: record.value.createdAt,
          uri: record.uri
        )
      )
    } catch {
      throw TangledError.decoding(error)
    }
    return prefix
      + data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func decode(
    _ cursor: String,
    repositoryDID: String,
    authorDID: String,
    status: PullRequestStatus?,
    order: BobbinSortOrder
  ) throws(TangledError) -> Position {
    guard cursor.hasPrefix(prefix) else {
      throw TangledError.invalidRequest(
        "--author requires a cursor returned by an author PDS listing"
      )
    }
    var encoded = String(cursor.dropFirst(prefix.count))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded),
      let position = try? JSONDecoder().decode(Position.self, from: data),
      position.version == 1
    else {
      throw TangledError.invalidRequest("invalid author pull request cursor")
    }
    guard position.repositoryDID == repositoryDID,
      position.authorDID == authorDID,
      position.status == status?.rawValue,
      position.order == order.rawValue
    else {
      throw TangledError.invalidRequest(
        "author pull request cursor does not match the current filters"
      )
    }
    return position
  }
}
