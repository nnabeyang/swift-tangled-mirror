import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private struct AccountRegistryDocument: Codable {
  let schemaVersion: Int
  let accounts: [AccountSession]
}

public final class FileAccountRegistryStore: AccountRegistryStoring, @unchecked Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> [AccountSession] {
    guard fileURL.isFileURL else { throw failure("registry location is not a file URL") }
    let directory = fileURL.deletingLastPathComponent()
    guard try validateDirectoryIfPresent(directory) else { return [] }
    let descriptor = registryOpen(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
    if descriptor < 0 {
      if errno == ENOENT { return [] }
      throw posixFailure("could not open account registry")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try validateFile(descriptor)
    do {
      let document = try JSONDecoder().decode(
        AccountRegistryDocument.self, from: try handle.readToEnd() ?? Data())
      guard document.schemaVersion == 1 else {
        throw AccountSessionRegistryError.invalidRegistry
      }
      return document.accounts
    } catch let error as AccountSessionRegistryError {
      throw error
    } catch {
      throw AccountSessionRegistryError.invalidRegistry
    }
  }

  public func write(_ accounts: [AccountSession]) throws {
    guard fileURL.isFileURL else { throw failure("registry location is not a file URL") }
    let data = try JSONEncoder().encode(
      AccountRegistryDocument(schemaVersion: 1, accounts: accounts))
    let directory = fileURL.deletingLastPathComponent()
    try prepareDirectory(directory)
    try validateExistingFileIfPresent()

    let temporary = directory.appendingPathComponent(
      ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
    var descriptor = registryOpen(
      temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw posixFailure("could not create account registry") }
    var removeTemporary = true
    defer {
      if descriptor >= 0 { _ = close(descriptor) }
      if removeTemporary { _ = temporary.path.withCString(unlink) }
    }
    guard fchmod(descriptor, mode_t(0o600)) == 0 else {
      throw posixFailure("could not secure account registry")
    }
    try data.withUnsafeBytes { bytes in
      var address = bytes.baseAddress
      var remaining = bytes.count
      while remaining > 0, let current = address {
        let count = DarwinOrGlibcWrite(descriptor, current, remaining)
        if count < 0 {
          if errno == EINTR { continue }
          throw posixFailure("could not write account registry")
        }
        remaining -= count
        address = current.advanced(by: count)
      }
    }
    guard fsync(descriptor) == 0 else { throw posixFailure("could not flush account registry") }
    guard close(descriptor) == 0 else {
      descriptor = -1
      throw posixFailure("could not close account registry")
    }
    descriptor = -1
    guard registryRename(temporary.path, fileURL.path) == 0 else {
      throw posixFailure("could not replace account registry")
    }
    removeTemporary = false
    try validateExistingFileIfPresent()
    let directoryDescriptor = registryOpen(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0)
    guard directoryDescriptor >= 0 else { throw posixFailure("could not open registry directory") }
    defer { _ = close(directoryDescriptor) }
    guard fsync(directoryDescriptor) == 0 else {
      throw posixFailure("could not flush registry directory")
    }
  }

  private func prepareDirectory(_ url: URL) throws {
    if try validateDirectoryIfPresent(url) { return }
    do {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      throw failure("could not create registry directory: \(error.localizedDescription)")
    }
    guard try validateDirectoryIfPresent(url) else {
      throw failure("registry directory was not created")
    }
  }

  private func validateDirectoryIfPresent(_ url: URL) throws -> Bool {
    guard let info = try registryMetadata(url.path) else { return false }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid(),
      info.st_mode & mode_t(0o777) == mode_t(0o700)
    else { throw failure("registry directory must be an owned mode 0700 directory") }
    return true
  }

  private func validateExistingFileIfPresent() throws {
    guard let info = try registryMetadata(fileURL.path) else { return }
    try validateFileMetadata(info)
  }

  private func validateFile(_ descriptor: Int32) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw posixFailure("could not inspect registry") }
    try validateFileMetadata(info)
  }

  private func validateFileMetadata(_ info: stat) throws {
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
      info.st_mode & mode_t(0o777) == mode_t(0o600), info.st_nlink == 1
    else { throw failure("account registry must be an owned mode 0600 regular file with one link") }
  }

  private func failure(_ message: String) -> TangledError {
    .sessionStoreFailure(message)
  }

  private func posixFailure(_ message: String) -> TangledError {
    failure("\(message): \(String(cString: strerror(errno)))")
  }
}

private func registryMetadata(_ path: String) throws -> stat? {
  var info = stat()
  if path.withCString({ lstat($0, &info) }) == 0 { return info }
  if errno == ENOENT { return nil }
  throw TangledError.sessionStoreFailure(
    "could not inspect account registry: \(String(cString: strerror(errno)))")
}

private func registryOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
  path.withCString { open($0, flags, mode) }
}

private func registryRename(_ source: String, _ destination: String) -> Int32 {
  source.withCString { sourcePointer in
    destination.withCString { rename(sourcePointer, $0) }
  }
}

private func DarwinOrGlibcWrite(
  _ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int
) -> Int {
  write(descriptor, buffer, count)
}

#if canImport(Security)
  import Security

  public final class KeychainAccountRegistryStore: AccountRegistryStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
      service: String = KeychainSessionStore.defaultService,
      account: String = "account-registry"
    ) {
      self.service = service
      self.account = account
    }

    public func load() throws -> [AccountSession] {
      var query = baseQuery
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: AnyObject?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return [] }
      guard status == errSecSuccess, let data = result as? Data else {
        throw TangledError.keychainFailure(status)
      }
      do {
        let document = try JSONDecoder().decode(AccountRegistryDocument.self, from: data)
        guard document.schemaVersion == 1 else {
          throw AccountSessionRegistryError.invalidRegistry
        }
        return document.accounts
      } catch let error as AccountSessionRegistryError {
        throw error
      } catch {
        throw AccountSessionRegistryError.invalidRegistry
      }
    }

    public func write(_ accounts: [AccountSession]) throws {
      let data = try JSONEncoder().encode(
        AccountRegistryDocument(schemaVersion: 1, accounts: accounts))
      let update = [kSecValueData as String: data]
      let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
      if updateStatus == errSecSuccess { return }
      guard updateStatus == errSecItemNotFound else {
        throw TangledError.keychainFailure(updateStatus)
      }
      var add = baseQuery
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(add as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw TangledError.keychainFailure(addStatus) }
    }

    private var baseQuery: [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
    }
  }
#endif
