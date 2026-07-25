import Foundation
import OAuth4Swift
import Testing

@testable import SwiftTangled

@Test func inMemoryStoreRoundTrip() throws {
  let store = InMemorySessionStore()
  #expect(store.load() == nil)
  let session = try SessionStoreTestHelpers.makeStoredSession()
  store.write(session)
  let loaded = store.load()
  #expect(loaded?.did == session.did)
  #expect(loaded?.handle == session.handle)
  #expect(loaded?.archive.tokenState.accessToken.value == "test-access")
  store.clear()
  #expect(store.load() == nil)
}

@Test func inMemoryStoreRefreshUpdatesTokenState() throws {
  let store = InMemorySessionStore()
  let session = try SessionStoreTestHelpers.makeStoredSession(accessToken: "old")
  store.write(session)

  let refreshedArchive = try SessionStoreTestHelpers.makeStoredSession(accessToken: "new").archive
  store.save(refreshedArchive.tokenState)

  let loaded = try #require(store.load())
  #expect(loaded.archive.tokenState.accessToken.value == "new")
  #expect(loaded.did == session.did)
}

@Test func inMemoryStoreSaveNilClearsSession() throws {
  let store = InMemorySessionStore()
  store.write(try SessionStoreTestHelpers.makeStoredSession())
  store.save(nil)
  #expect(store.load() == nil)
}
