import OAuth4Swift

public struct StoredSession: Sendable, Codable {
  public let did: String
  public let handle: String
  public let profile: AuthenticationProfile?
  public let clientID: String?
  public var archive: OAuth.SessionState.Archive

  public var resolvedClientID: String {
    clientID ?? legacyTangledCLIClientID
  }

  public init(
    did: String,
    handle: String,
    profile: AuthenticationProfile? = nil,
    clientID: String? = nil,
    archive: OAuth.SessionState.Archive
  ) {
    self.did = did
    self.handle = handle
    self.profile = profile
    self.clientID = clientID
    self.archive = archive
  }

  private enum CodingKeys: String, CodingKey {
    case did
    case handle
    case profile
    case clientID = "clientId"
    case archive
  }
}
