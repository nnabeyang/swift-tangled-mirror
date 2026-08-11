import OAuth4Swift

public struct StoredSession: Sendable, Codable {
  public let did: String
  public let handle: String
  public let profile: AuthenticationProfile?
  public var archive: OAuth.SessionState.Archive

  public init(
    did: String,
    handle: String,
    profile: AuthenticationProfile? = nil,
    archive: OAuth.SessionState.Archive
  ) {
    self.did = did
    self.handle = handle
    self.profile = profile
    self.archive = archive
  }
}
