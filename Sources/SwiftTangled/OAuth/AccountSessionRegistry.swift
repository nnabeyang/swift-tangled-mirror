import Foundation
import Synchronization

public struct AccountSession: Codable, Equatable, Sendable {
  public let did: String
  public var handle: String
  public var isActive: Bool

  public init(did: String, handle: String, isActive: Bool) {
    self.did = did
    self.handle = handle
    self.isActive = isActive
  }
}

public enum AccountSessionRegistryError: Error, Equatable, Sendable {
  case accountNotFound(String)
  case ambiguousHandle(String)
  case invalidRegistry
  case migrationVerificationFailed
}

extension AccountSessionRegistryError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .accountNotFound(let identifier): "No stored account matches '\(identifier)'"
    case .ambiguousHandle(let handle):
      "Multiple stored accounts use '@\(handle)'; select one by DID"
    case .invalidRegistry: "The account session registry is invalid"
    case .migrationVerificationFailed: "The existing session could not be migrated safely"
    }
  }
}

public protocol AccountRegistryStoring: Sendable {
  func load() throws -> [AccountSession]
  func write(_ accounts: [AccountSession]) throws
}

public final class InMemoryAccountRegistryStore: AccountRegistryStoring, Sendable {
  private let accounts: Mutex<[AccountSession]>

  public init(accounts: [AccountSession] = []) {
    self.accounts = Mutex(accounts)
  }

  public func load() -> [AccountSession] {
    accounts.withLock { $0 }
  }

  public func write(_ newAccounts: [AccountSession]) {
    accounts.withLock { $0 = newAccounts }
  }
}

public final class AccountSessionRegistry: @unchecked Sendable {
  private let metadataStore: any AccountRegistryStoring
  private let sessionStoreFactory: (String) -> any SessionStore
  private let legacyStore: (any SessionStore)?
  private let lock = Mutex(())

  public init(
    metadataStore: any AccountRegistryStoring,
    sessionStoreFactory: @escaping (String) -> any SessionStore,
    legacyStore: (any SessionStore)? = nil
  ) {
    self.metadataStore = metadataStore
    self.sessionStoreFactory = sessionStoreFactory
    self.legacyStore = legacyStore
  }

  public func accounts() throws -> [AccountSession] {
    try lock.withLock { _ in
      try migrateLegacyIfNeeded()
      return try validatedAccounts()
    }
  }

  public func activeAccount() throws -> AccountSession? {
    try accounts().first(where: \.isActive)
  }

  public func account(matching identifier: String) throws -> AccountSession {
    try lock.withLock { _ in
      try migrateLegacyIfNeeded()
      return try resolve(identifier, in: validatedAccounts())
    }
  }

  public func sessionStore(for identifier: String) throws -> any SessionStore {
    let account = try account(matching: identifier)
    return sessionStoreFactory(account.did)
  }

  public func activeSessionStore() throws -> (AccountSession, any SessionStore)? {
    guard let account = try activeAccount() else { return nil }
    return (account, sessionStoreFactory(account.did))
  }

  public func store(_ session: StoredSession, makeActive: Bool = true) throws {
    try lock.withLock { _ in
      try migrateLegacyIfNeeded()
      let store = sessionStoreFactory(session.did)
      try store.write(session)
      guard let persisted = try store.load(), try sessionsMatch(session, persisted) else {
        throw AccountSessionRegistryError.migrationVerificationFailed
      }

      var accounts = try validatedAccounts()
      if let index = accounts.firstIndex(where: { $0.did == session.did }) {
        accounts[index].handle = session.handle
      } else {
        accounts.append(AccountSession(did: session.did, handle: session.handle, isActive: false))
      }
      if makeActive {
        for index in accounts.indices {
          accounts[index].isActive = accounts[index].did == session.did
        }
      } else if !accounts.contains(where: \.isActive) {
        setDeterministicActive(&accounts)
      }
      try metadataStore.write(sorted(accounts))
    }
  }

  @discardableResult
  public func switchActive(to identifier: String) throws -> AccountSession {
    try lock.withLock { _ in
      try migrateLegacyIfNeeded()
      var accounts = try validatedAccounts()
      let selected = try resolve(identifier, in: accounts)
      for index in accounts.indices {
        accounts[index].isActive = accounts[index].did == selected.did
      }
      try metadataStore.write(sorted(accounts))
      return AccountSession(did: selected.did, handle: selected.handle, isActive: true)
    }
  }

  @discardableResult
  public func remove(_ identifier: String) throws -> AccountSession {
    try lock.withLock { _ in
      try migrateLegacyIfNeeded()
      var accounts = try validatedAccounts()
      let selected = try resolve(identifier, in: accounts)
      try sessionStoreFactory(selected.did).clear()
      accounts.removeAll { $0.did == selected.did }
      if selected.isActive || !accounts.contains(where: \.isActive) {
        setDeterministicActive(&accounts)
      }
      try metadataStore.write(sorted(accounts))
      return selected
    }
  }

  @discardableResult
  public func removeAll() throws -> [AccountSession] {
    try lock.withLock { _ in
      try migrateLegacyIfNeeded()
      let accounts = try validatedAccounts()
      for account in accounts {
        try sessionStoreFactory(account.did).clear()
      }
      try metadataStore.write([])
      return accounts
    }
  }

  private func migrateLegacyIfNeeded() throws {
    guard try metadataStore.load().isEmpty, let legacyStore, let legacy = try legacyStore.load()
    else { return }

    let destination = sessionStoreFactory(legacy.did)
    try destination.write(legacy)
    guard let persisted = try destination.load(), try sessionsMatch(legacy, persisted) else {
      throw AccountSessionRegistryError.migrationVerificationFailed
    }
    let account = AccountSession(did: legacy.did, handle: legacy.handle, isActive: true)
    try metadataStore.write([account])
    guard try metadataStore.load() == [account] else {
      throw AccountSessionRegistryError.migrationVerificationFailed
    }
    try legacyStore.clear()
  }

  private func validatedAccounts() throws -> [AccountSession] {
    let accounts = try metadataStore.load()
    guard Set(accounts.map(\.did)).count == accounts.count,
      accounts.filter(\.isActive).count <= 1,
      accounts.allSatisfy({ !$0.did.isEmpty && !$0.handle.isEmpty })
    else { throw AccountSessionRegistryError.invalidRegistry }
    var normalized = accounts
    if !normalized.isEmpty, !normalized.contains(where: \.isActive) {
      setDeterministicActive(&normalized)
      try metadataStore.write(sorted(normalized))
    }
    return sorted(normalized)
  }

  private func resolve(_ identifier: String, in accounts: [AccountSession]) throws -> AccountSession {
    if let did = accounts.first(where: { $0.did == identifier }) {
      return did
    }
    let matches = accounts.filter { $0.handle.caseInsensitiveCompare(identifier) == .orderedSame }
    if matches.count > 1 {
      throw AccountSessionRegistryError.ambiguousHandle(identifier)
    }
    guard let match = matches.first else {
      throw AccountSessionRegistryError.accountNotFound(identifier)
    }
    return match
  }

  private func sorted(_ accounts: [AccountSession]) -> [AccountSession] {
    accounts.sorted {
      let handles = $0.handle.localizedCaseInsensitiveCompare($1.handle)
      return handles == .orderedSame ? $0.did < $1.did : handles == .orderedAscending
    }
  }

  private func setDeterministicActive(_ accounts: inout [AccountSession]) {
    guard let selected = sorted(accounts).first else { return }
    for index in accounts.indices {
      accounts[index].isActive = accounts[index].did == selected.did
    }
  }

  private func sessionsMatch(_ lhs: StoredSession, _ rhs: StoredSession) throws -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(lhs) == encoder.encode(rhs)
  }
}
