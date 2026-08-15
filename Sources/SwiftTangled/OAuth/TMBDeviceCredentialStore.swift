import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public enum TMBDeviceCredentialStoreError: Error, Equatable, Sendable {
  case invalidInstance
  case invalidState
  case unsupportedSchemaVersion
  case unavailable(String)
}

extension TMBDeviceCredentialStoreError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidInstance:
      "TMB instance must start with a lowercase letter and contain only lowercase letters, digits, or hyphens"
    case .invalidState: "TMB device state is invalid"
    case .unsupportedSchemaVersion: "TMB device state uses an unsupported schema version"
    case .unavailable(let message): "TMB device state is unavailable: \(message)"
    }
  }
}

public struct TMBDeviceRegistration: Sendable {
  public static let schemaVersion = 1

  public let instance: String
  public let origin: TMBOrigin
  public var credentials: TMBDeviceCredentials

  public init(
    instance: String,
    origin: TMBOrigin,
    credentials: TMBDeviceCredentials
  ) throws {
    guard Self.validInstance(instance) else {
      throw TMBDeviceCredentialStoreError.invalidInstance
    }
    self.instance = instance
    self.origin = origin
    self.credentials = credentials
  }

  public static func validInstance(_ value: String) -> Bool {
    value.range(of: "^[a-z][a-z0-9-]{0,31}$", options: .regularExpression) != nil
  }
}

public protocol TMBDeviceCredentialStoring: Sendable {
  func load() throws -> TMBDeviceRegistration?
  func write(_ registration: TMBDeviceRegistration) throws
  func clear() throws
}

public final class FileTMBDeviceCredentialStore: TMBDeviceCredentialStoring, @unchecked Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> TMBDeviceRegistration? {
    guard fileURL.isFileURL else { throw failure("location is not a file URL") }
    let directoryURL = fileURL.deletingLastPathComponent()
    guard try validateDirectoryIfPresent(at: directoryURL) else { return nil }
    let descriptor = try openExistingFile()
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try validateFile(descriptor: descriptor)
      let data = try handle.readToEnd() ?? Data()
      let stored = try JSONDecoder().decode(StoredRegistration.self, from: data)
      guard stored.schemaVersion == TMBDeviceRegistration.schemaVersion else {
        throw TMBDeviceCredentialStoreError.unsupportedSchemaVersion
      }
      guard !stored.deviceID.isEmpty else {
        throw TMBDeviceCredentialStoreError.invalidState
      }
      return try TMBDeviceRegistration(
        instance: stored.instance,
        origin: TMBOrigin(stored.origin),
        credentials: TMBDeviceCredentials(
          deviceID: stored.deviceID,
          nonce: stored.nonce,
          proofKey: TMBProofKey(rawRepresentation: stored.proofKey)
        )
      )
    } catch let error as TMBDeviceCredentialStoreError {
      throw error
    } catch is DecodingError {
      throw TMBDeviceCredentialStoreError.invalidState
    } catch is TMBClientError {
      throw TMBDeviceCredentialStoreError.invalidState
    } catch {
      throw failure("could not read device state")
    }
  }

  public func write(_ registration: TMBDeviceRegistration) throws {
    guard fileURL.isFileURL else { throw failure("location is not a file URL") }
    let stored = StoredRegistration(
      schemaVersion: TMBDeviceRegistration.schemaVersion,
      instance: registration.instance,
      origin: registration.origin.url.absoluteString,
      deviceID: registration.credentials.deviceID,
      nonce: registration.credentials.nonce,
      proofKey: registration.credentials.proofKey.rawRepresentation
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data: Data
    do {
      data = try encoder.encode(stored)
    } catch {
      throw TMBDeviceCredentialStoreError.invalidState
    }

    let directoryURL = fileURL.deletingLastPathComponent()
    try prepareDirectory(at: directoryURL)
    try validateExistingFileIfPresent()
    let temporaryURL = directoryURL.appendingPathComponent(
      ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
    )
    var descriptor: Int32 = -1
    var removeTemporaryFile = true
    defer {
      if descriptor >= 0 { _ = close(descriptor) }
      if removeTemporaryFile { _ = unlink(temporaryURL.path) }
    }
    descriptor = open(
      temporaryURL.path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      mode_t(0o600)
    )
    guard descriptor >= 0 else { throw posixFailure("could not create temporary file") }
    guard fchmod(descriptor, mode_t(0o600)) == 0 else {
      throw posixFailure("could not secure temporary file")
    }
    try writeAll(data, to: descriptor)
    guard fsync(descriptor) == 0 else { throw posixFailure("could not flush temporary file") }
    guard close(descriptor) == 0 else {
      descriptor = -1
      throw posixFailure("could not close temporary file")
    }
    descriptor = -1
    guard rename(temporaryURL.path, fileURL.path) == 0 else {
      throw posixFailure("could not replace device state")
    }
    removeTemporaryFile = false
    try validateExistingFileIfPresent()
    let directoryDescriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0)
    guard directoryDescriptor >= 0 else { throw posixFailure("could not open directory") }
    defer { _ = close(directoryDescriptor) }
    guard fsync(directoryDescriptor) == 0 else { throw posixFailure("could not flush directory") }
  }

  public func clear() throws {
    guard fileURL.isFileURL else { throw failure("location is not a file URL") }
    let directoryURL = fileURL.deletingLastPathComponent()
    guard try validateDirectoryIfPresent(at: directoryURL) else { return }
    guard try metadata(at: fileURL.path) != nil else { return }
    try validateExistingFileIfPresent()
    guard unlink(fileURL.path) == 0 || errno == ENOENT else {
      throw posixFailure("could not remove device state")
    }
  }

  private func prepareDirectory(at directoryURL: URL) throws {
    if try validateDirectoryIfPresent(at: directoryURL) { return }
    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw failure("could not create directory")
    }
    guard try validateDirectoryIfPresent(at: directoryURL) else {
      throw failure("directory was not created")
    }
  }

  private func validateDirectoryIfPresent(at directoryURL: URL) throws -> Bool {
    guard let info = try metadata(at: directoryURL.path) else { return false }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      throw failure("parent is not a directory")
    }
    guard info.st_uid == geteuid() else { throw failure("directory has another owner") }
    guard info.st_mode & mode_t(0o777) == mode_t(0o700) else {
      throw failure("directory permissions must be 0700")
    }
    return true
  }

  private func validateExistingFileIfPresent() throws {
    guard let info = try metadata(at: fileURL.path) else { return }
    try validateFileMetadata(info)
  }

  private func validateFile(descriptor: Int32) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw posixFailure("could not inspect file") }
    try validateFileMetadata(info)
  }

  private func validateFileMetadata(_ info: stat) throws {
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      throw failure("device state must be a regular file")
    }
    guard info.st_uid == geteuid() else { throw failure("device state has another owner") }
    guard info.st_mode & mode_t(0o777) == mode_t(0o600) else {
      throw failure("device state permissions must be 0600")
    }
    guard info.st_nlink == 1 else { throw failure("device state must not have hard links") }
  }

  private func openExistingFile() throws -> Int32 {
    let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
    if descriptor >= 0 { return descriptor }
    if errno == ENOENT { return -1 }
    throw posixFailure("could not open device state")
  }

  private func metadata(at path: String) throws -> stat? {
    var info = stat()
    if path.withCString({ lstat($0, &info) }) == 0 { return info }
    if errno == ENOENT { return nil }
    throw posixFailure("could not inspect device state")
  }

  private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard var address = bytes.baseAddress else { return }
      var remaining = bytes.count
      while remaining > 0 {
        let count = tmbSystemWrite(descriptor, address, remaining)
        if count < 0 {
          if errno == EINTR { continue }
          throw posixFailure("could not write temporary file")
        }
        remaining -= count
        address = address.advanced(by: count)
      }
    }
  }

  private func failure(_ message: String) -> TMBDeviceCredentialStoreError {
    .unavailable(message)
  }

  private func posixFailure(_ message: String) -> TMBDeviceCredentialStoreError {
    .unavailable("\(message): \(String(cString: strerror(errno)))")
  }
}

private struct StoredRegistration: Codable {
  let schemaVersion: Int
  let instance: String
  let origin: String
  let deviceID: String
  let nonce: String?
  let proofKey: Data
}

private func tmbSystemWrite(
  _ descriptor: Int32,
  _ buffer: UnsafeRawPointer,
  _ count: Int
) -> Int {
  #if canImport(Darwin)
    Darwin.write(descriptor, buffer, count)
  #elseif canImport(Glibc)
    Glibc.write(descriptor, buffer, count)
  #else
    -1
  #endif
}
