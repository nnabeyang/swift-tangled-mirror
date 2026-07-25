import Foundation
import SwiftAtproto

public enum StarSubject: Codable, Equatable, Hashable, Sendable {
  case repository(did: String)
  case string(uri: String)

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "sh.tangled.feed.star#repo":
      self = .repository(did: try container.decode(String.self, forKey: .did))
    case "sh.tangled.feed.star#string":
      self = .string(uri: try container.decode(String.self, forKey: .uri))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unsupported star subject type"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .repository(let did):
      try container.encode("sh.tangled.feed.star#repo", forKey: .type)
      try container.encode(did, forKey: .did)
    case .string(let uri):
      try container.encode("sh.tangled.feed.star#string", forKey: .type)
      try container.encode(uri, forKey: .uri)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case type = "$type"
    case did
    case uri
  }
}

public struct Star: Codable, Equatable, Hashable, Sendable {
  public let subject: StarSubject
  public let createdAt: FormatString<Date>

  public init(subject: StarSubject, createdAt: FormatString<Date>) {
    self.subject = subject
    self.createdAt = createdAt
  }
}

public struct Follow: Codable, Equatable, Hashable, Sendable {
  public let subjectDID: String
  public let createdAt: FormatString<Date>

  public init(subjectDID: String, createdAt: FormatString<Date>) {
    self.subjectDID = subjectDID
    self.createdAt = createdAt
  }
}
