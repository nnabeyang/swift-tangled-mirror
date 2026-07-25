import OAuth4Swift

public protocol SessionStore: OAuthPersistenceDelegate {
  func load() throws -> StoredSession?
  func write(_ session: StoredSession) throws
  func clear() throws
}
