import Foundation
import OAuth4Swift
import Synchronization

public final class InMemorySessionStore: SessionStore {
  private let state = Mutex<StoredSession?>(nil)

  public init() {}

  public func load() -> StoredSession? {
    state.withLock { $0 }
  }

  public func write(_ session: StoredSession) {
    state.withLock { $0 = session }
  }

  public func clear() {
    state.withLock { $0 = nil }
  }

  public nonisolated func save(_ newState: OAuth.SessionState.TokenState?) {
    state.withLock { current in
      if let newState {
        if var updated = current {
          updated.archive.tokenState = newState
          current = updated
        }
      } else {
        current = nil
      }
    }
  }
}
