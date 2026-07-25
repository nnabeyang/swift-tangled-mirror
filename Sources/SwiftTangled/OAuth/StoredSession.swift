import OAuth4Swift

public struct StoredSession: Sendable, Codable {
  public let did: String
  public let handle: String
  public var archive: OAuth.SessionState.Archive

  public init(did: String, handle: String, archive: OAuth.SessionState.Archive) {
    self.did = did
    self.handle = handle
    self.archive = archive
  }
}
