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
