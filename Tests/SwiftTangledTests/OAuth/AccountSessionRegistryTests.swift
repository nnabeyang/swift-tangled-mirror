import Foundation
import Testing

@testable import SwiftTangled

@Suite struct AccountSessionRegistryTests {
  @Test func storesSwitchesAndRemovesAccountsDeterministically() throws {
    let stores = AccountStoreBox()
    let metadata = InMemoryAccountRegistryStore()
    let registry = AccountSessionRegistry(
      metadataStore: metadata,
      sessionStoreFactory: stores.store(for:)
    )
    try registry.store(session(did: "did:plc:bob", handle: "bob.test"))
    try registry.store(session(did: "did:plc:alice", handle: "alice.test"))

    #expect(try registry.activeAccount()?.did == "did:plc:alice")
    #expect(try registry.switchActive(to: "bob.test").did == "did:plc:bob")
    #expect(try registry.remove("did:plc:bob").did == "did:plc:bob")
    #expect(try registry.activeAccount()?.did == "did:plc:alice")
    #expect(stores.store(for: "did:plc:bob").load() == nil)
  }

  @Test func rejectsAmbiguousHandlesAndAcceptsDIDs() throws {
    let stores = AccountStoreBox()
    let metadata = InMemoryAccountRegistryStore(accounts: [
      AccountSession(did: "did:plc:one", handle: "same.test", isActive: true),
      AccountSession(did: "did:plc:two", handle: "same.test", isActive: false),
    ])
    let registry = AccountSessionRegistry(
      metadataStore: metadata,
      sessionStoreFactory: stores.store(for:)
    )

    #expect(throws: AccountSessionRegistryError.ambiguousHandle("same.test")) {
      _ = try registry.account(matching: "same.test")
    }
    #expect(try registry.account(matching: "did:plc:two").did == "did:plc:two")
  }

  @Test func migratesLegacyOnlyAfterVerifyingTheNewCopy() throws {
    let stores = AccountStoreBox()
    let legacy = InMemorySessionStore()
    let original = try session(did: "did:plc:legacy", handle: "legacy.test")
    legacy.write(original)
    let registry = AccountSessionRegistry(
      metadataStore: InMemoryAccountRegistryStore(),
      sessionStoreFactory: stores.store(for:),
      legacyStore: legacy
    )

    #expect(
      try registry.accounts() == [
        AccountSession(did: "did:plc:legacy", handle: "legacy.test", isActive: true)
      ])
    #expect(legacy.load() == nil)
    #expect(stores.store(for: original.did).load()?.did == original.did)
  }

  @Test func selectedStoreDoesNotFollowLaterActiveChanges() throws {
    let stores = AccountStoreBox()
    let registry = AccountSessionRegistry(
      metadataStore: InMemoryAccountRegistryStore(),
      sessionStoreFactory: stores.store(for:)
    )
    try registry.store(session(did: "did:plc:one", handle: "one.test"))
    try registry.store(session(did: "did:plc:two", handle: "two.test"))
    let selected = try registry.sessionStore(for: "did:plc:one")
    _ = try registry.switchActive(to: "did:plc:two")

    try selected.write(session(did: "did:plc:one", handle: "updated.test"))
    #expect(stores.store(for: "did:plc:one").load()?.handle == "updated.test")
    #expect(stores.store(for: "did:plc:two").load()?.handle == "two.test")
  }

  @Test func storesAndVerifiesThePersistedClientID() throws {
    let stores = AccountStoreBox()
    let registry = AccountSessionRegistry(
      metadataStore: InMemoryAccountRegistryStore(),
      sessionStoreFactory: stores.store(for:)
    )
    let original = try SessionStoreTestHelpers.makeStoredSession(
      storedClientID: "https://client.example/metadata.json"
    )

    try registry.store(original)

    #expect(
      try registry.activeSessionStore()?.1.load()?.clientID
        == "https://client.example/metadata.json"
    )
  }

  private func session(did: String, handle: String) throws -> StoredSession {
    try SessionStoreTestHelpers.makeStoredSession(did: did, handle: handle)
  }
}

private final class AccountStoreBox: @unchecked Sendable {
  private var stores: [String: InMemorySessionStore] = [:]
  private let lock = NSLock()

  func store(for did: String) -> InMemorySessionStore {
    lock.withLock {
      if let store = stores[did] { return store }
      let store = InMemorySessionStore()
      stores[did] = store
      return store
    }
  }
}
