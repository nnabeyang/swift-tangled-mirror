#if canImport(Security) && KeychainIntegrationTests
  import Foundation
  import Testing

  @testable import SwiftTangled

  @Suite
  struct KeychainSessionStoreTests {
    private func makeIsolatedStore() -> KeychainSessionStore {
      let service = "com.nnabeyang.tng.test.\(UUID().uuidString)"
      return KeychainSessionStore(service: service)
    }

    @Test func keychainStoreRoundTrip() throws {
      let store = makeIsolatedStore()
      defer { try? store.clear() }

      #expect(try store.load() == nil)

      let session = try SessionStoreTestHelpers.makeStoredSession()
      try store.write(session)

      let loaded = try #require(try store.load())
      #expect(loaded.did == session.did)
      #expect(loaded.handle == session.handle)
      #expect(loaded.archive.tokenState.accessToken.value == "test-access")

      try store.clear()
      #expect(try store.load() == nil)
    }

    @Test func keychainStoreOverwritesExistingEntry() throws {
      let store = makeIsolatedStore()
      defer { try? store.clear() }

      try store.write(try SessionStoreTestHelpers.makeStoredSession(handle: "alice.test"))
      try store.write(try SessionStoreTestHelpers.makeStoredSession(handle: "bob.test"))

      let loaded = try #require(try store.load())
      #expect(loaded.handle == "bob.test")
    }

    @Test func keychainStoreSaveNilClears() throws {
      let store = makeIsolatedStore()
      defer { try? store.clear() }
      try store.write(try SessionStoreTestHelpers.makeStoredSession())
      store.save(nil)
      #expect(try store.load() == nil)
    }
  }
#endif
