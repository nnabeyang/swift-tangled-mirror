import OAuth4Swift

public protocol OAuthPersistenceDelegate: AnyObject, Sendable {
  nonisolated func save(_ newState: OAuth.SessionState.TokenState?)
}
