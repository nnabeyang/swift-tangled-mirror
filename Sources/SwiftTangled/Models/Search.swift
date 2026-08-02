import Foundation
import SwiftAtproto

public enum BobbinSortOrder: String, Codable, Sendable {
  case ascending = "asc"
  case descending = "desc"
}

public struct SearchOptions: Equatable, Sendable {
  public let nsid: String?
  public let authorDID: String?
  public let repoDID: String?
  public let since: FormatString<Date>?
  public let until: FormatString<Date>?
  public let cursor: String?
  public let limit: Int?

  public init(
    nsid: String? = nil,
    authorDID: String? = nil,
    repoDID: String? = nil,
    since: FormatString<Date>? = nil,
    until: FormatString<Date>? = nil,
    cursor: String? = nil,
    limit: Int? = nil
  ) {
    self.nsid = nsid
    self.authorDID = authorDID
    self.repoDID = repoDID
    self.since = since
    self.until = until
    self.cursor = cursor
    self.limit = limit
  }
}

extension SearchOptions {
  package func validateDates() throws(TangledError) {
    let parsedSince: Date?
    if let since {
      guard let date = since.typed else {
        throw TangledError.invalidRequest("since must be a valid AT Protocol datetime")
      }
      parsedSince = date
    } else {
      parsedSince = nil
    }

    let parsedUntil: Date?
    if let until {
      guard let date = until.typed else {
        throw TangledError.invalidRequest("until must be a valid AT Protocol datetime")
      }
      parsedUntil = date
    } else {
      parsedUntil = nil
    }

    if let parsedSince, let parsedUntil, parsedSince > parsedUntil {
      throw TangledError.invalidRequest("since must not be later than until")
    }
  }
}

public struct SearchHit: Codable, Equatable, Hashable, Sendable {
  public let uri: String
  public let cid: String?
  public let nsid: String
  public let score: Double
  public let value: JSONValue

  public init(
    uri: String,
    cid: String? = nil,
    nsid: String,
    score: Double,
    value: JSONValue
  ) {
    self.uri = uri
    self.cid = cid
    self.nsid = nsid
    self.score = score
    self.value = value
  }
}
