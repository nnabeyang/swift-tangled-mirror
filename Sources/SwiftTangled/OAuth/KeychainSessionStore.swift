#if canImport(Security)
  import Foundation
  import OAuth4Swift
  import Security

  public final class KeychainSessionStore: SessionStore {
    public static let defaultService = "com.nnabeyang.tng"

    private let service: String
    private let account: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = KeychainSessionStore.defaultService, account: String = "active") {
      self.service = service
      self.account = account
    }

    public func load() throws(TangledError) -> StoredSession? {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: AnyObject?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound {
        return nil
      }
      guard status == errSecSuccess else {
        throw TangledError.keychainFailure(status)
      }
      guard let data = result as? Data else {
        return nil
      }
      do {
        return try decoder.decode(StoredSession.self, from: data)
      } catch {
        throw TangledError.decoding(error)
      }
    }

    public func write(_ session: StoredSession) throws(TangledError) {
      let data: Data
      do {
        data = try encoder.encode(session)
      } catch {
        throw TangledError.decoding(error)
      }

      let baseQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]

      let updateAttrs: [String: Any] = [
        kSecValueData as String: data
      ]

      let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
      if updateStatus == errSecSuccess {
        return
      }
      if updateStatus == errSecItemNotFound {
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
          throw TangledError.keychainFailure(addStatus)
        }
        return
      }
      throw TangledError.keychainFailure(updateStatus)
    }

    public func clear() throws(TangledError) {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
      let status = SecItemDelete(query as CFDictionary)
      if status == errSecItemNotFound || status == errSecSuccess {
        return
      }
      throw TangledError.keychainFailure(status)
    }

    public nonisolated func save(_ newState: OAuth.SessionState.TokenState?) {
      if let newState {
        if var current = try? load() {
          current.archive.tokenState = newState
          try? write(current)
        }
      } else {
        try? clear()
      }
    }
  }
#endif
