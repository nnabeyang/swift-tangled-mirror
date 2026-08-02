import Foundation
import SwiftAtproto

public struct Repository: Codable, Equatable, Hashable, Sendable {
  public let name: String?
  public let knot: String
  public let spindle: String?
  public let description: String?
  public let website: String?
  public let topics: [String]
  public let source: String?
  public let labels: [String]
  public let repoDID: String?
  public let createdAt: FormatString<Date>

  public init(
    name: String? = nil,
    knot: String,
    spindle: String? = nil,
    description: String? = nil,
    website: String? = nil,
    topics: [String] = [],
    source: String? = nil,
    labels: [String] = [],
    repoDID: String? = nil,
    createdAt: FormatString<Date>
  ) {
    self.name = name
    self.knot = knot
    self.spindle = spindle
    self.description = description
    self.website = website
    self.topics = topics
    self.source = source
    self.labels = labels
    self.repoDID = repoDID
    self.createdAt = createdAt
  }
}

public struct RepositoryView: Codable, Equatable, Sendable {
  public let record: TangledRecord<Repository>
  public let defaultBranch: GitDefaultBranch?

  public init(
    record: TangledRecord<Repository>,
    defaultBranch: GitDefaultBranch?
  ) {
    self.record = record
    self.defaultBranch = defaultBranch
  }

  private enum CodingKeys: String, CodingKey {
    case uri
    case cid
    case value
    case defaultBranch
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    record = TangledRecord(
      uri: try values.decode(String.self, forKey: .uri),
      cid: try values.decodeIfPresent(String.self, forKey: .cid),
      value: try values.decode(Repository.self, forKey: .value)
    )
    defaultBranch = try values.decodeIfPresent(GitDefaultBranch.self, forKey: .defaultBranch)
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(record.uri, forKey: .uri)
    try values.encodeIfPresent(record.cid, forKey: .cid)
    try values.encode(record.value, forKey: .value)
    try values.encodeIfPresent(defaultBranch, forKey: .defaultBranch)
  }
}
