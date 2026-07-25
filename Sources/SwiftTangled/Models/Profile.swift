public struct BlobReference: Codable, Equatable, Hashable, Sendable {
  public let cid: String
  public let mimeType: String
  public let size: Int

  public init(cid: String, mimeType: String, size: Int) {
    self.cid = cid
    self.mimeType = mimeType
    self.size = size
  }
}

public struct Profile: Codable, Equatable, Hashable, Sendable {
  public let avatar: BlobReference?
  public let bluesky: Bool
  public let description: String?
  public let links: [String]
  public let location: String?
  public let pinnedRepositories: [String]
  public let preferredHandle: String?
  public let pronouns: String?
  public let stats: [String]

  public init(
    avatar: BlobReference? = nil,
    bluesky: Bool,
    description: String? = nil,
    links: [String] = [],
    location: String? = nil,
    pinnedRepositories: [String] = [],
    preferredHandle: String? = nil,
    pronouns: String? = nil,
    stats: [String] = []
  ) {
    self.avatar = avatar
    self.bluesky = bluesky
    self.description = description
    self.links = links
    self.location = location
    self.pinnedRepositories = pinnedRepositories
    self.preferredHandle = preferredHandle
    self.pronouns = pronouns
    self.stats = stats
  }
}
