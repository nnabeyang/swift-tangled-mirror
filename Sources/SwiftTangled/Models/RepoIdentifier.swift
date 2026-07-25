public struct RepoIdentifier: Hashable, Sendable, Codable {
  public let did: String
  public let knot: String
  public let name: String

  public init(did: String, knot: String, name: String) {
    self.did = did
    self.knot = knot
    self.name = name
  }
}
