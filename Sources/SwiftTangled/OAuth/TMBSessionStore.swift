import Foundation
import TangledLexicons

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public enum TMBSessionStoreError: Error, Equatable, Sendable {
  case invalidState
  case unsupportedSchemaVersion
  case unavailable(String)
}

extension TMBSessionStoreError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidState: "TMB OAuth session state is invalid"
    case .unsupportedSchemaVersion: "TMB OAuth session state uses an unsupported schema version"
    case .unavailable(let message): "TMB OAuth session state is unavailable: \(message)"
    }
  }
}

public struct TMBSession: Sendable {
  public static let schemaVersion = 1

  public let instance: String
  public let origin: TMBOrigin
  public let accountDID: String
  public let handle: String
  public var accessToken: String
  public var tokenType: String
  public var expiresAt: Date
  public var sessionID: String
  public let proofKey: TMBProofKey
  public var refreshProof: Org.Nnabeyang.TmbDefs_ProofRequest
  public var pdsNonce: String?
  let revision: String

  public init(
    instance: String,
    origin: TMBOrigin,
    accountDID: String,
    handle: String,
    accessToken: String,
    tokenType: String,
    expiresAt: Date,
    sessionID: String,
    proofKey: TMBProofKey,
    refreshProof: Org.Nnabeyang.TmbDefs_ProofRequest,
    pdsNonce: String? = nil,
    revision: String = UUID().uuidString
  ) throws {
    guard TMBDeviceRegistration.validInstance(instance), accountDID.hasPrefix("did:"),
      !handle.isEmpty, !accessToken.isEmpty, tokenType.lowercased() == "dpop",
      !sessionID.isEmpty, URL(string: refreshProof.endpoint.rawValue)?.scheme == "https"
    else { throw TMBSessionStoreError.invalidState }
    self.instance = instance
    self.origin = origin
    self.accountDID = accountDID
    self.handle = handle
    self.accessToken = accessToken
    self.tokenType = tokenType
    self.expiresAt = expiresAt
    self.sessionID = sessionID
    self.proofKey = proofKey
    self.refreshProof = refreshProof
    self.pdsNonce = pdsNonce
    self.revision = revision
  }
}

public protocol TMBSessionStoring: Sendable {
  func load() throws -> TMBSession?
  func write(_ session: TMBSession) throws
  func replace(_ session: TMBSession, ifCurrentRevision revision: String) throws -> Bool
  func clear() throws
}

extension TMBSessionStoring {
  public func replace(_ session: TMBSession, ifCurrentRevision revision: String) throws -> Bool {
    guard try load()?.revision == revision else { return false }
    try write(session)
    return true
  }
}

public final class FileTMBSessionStore: TMBSessionStoring, @unchecked Sendable {
  public let fileURL: URL

  public init(fileURL: URL) { self.fileURL = fileURL }

  public func load() throws -> TMBSession? {
    guard fileURL.isFileURL else { throw failure("location is not a file URL") }
    guard try validateDirectoryIfPresent(fileURL.deletingLastPathComponent()) else { return nil }
    let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw posixFailure("could not open session state")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try validateFile(descriptor)
      let stored = try JSONDecoder().decode(StoredTMBSession.self, from: handle.readToEnd() ?? Data())
      guard stored.schemaVersion == TMBSession.schemaVersion else {
        throw TMBSessionStoreError.unsupportedSchemaVersion
      }
      return try TMBSession(
        instance: stored.instance,
        origin: TMBOrigin(stored.origin),
        accountDID: stored.accountDID,
        handle: stored.handle,
        accessToken: stored.accessToken,
        tokenType: stored.tokenType,
        expiresAt: stored.expiresAt,
        sessionID: stored.sessionID,
        proofKey: TMBProofKey(rawRepresentation: stored.proofKey),
        refreshProof: stored.refreshProof,
        pdsNonce: stored.pdsNonce,
        revision: stored.revision ?? stored.accessToken
      )
    } catch let error as TMBSessionStoreError {
      throw error
    } catch {
      throw TMBSessionStoreError.invalidState
    }
  }

  public func write(_ session: TMBSession) throws {
    guard fileURL.isFileURL else { throw failure("location is not a file URL") }
    let stored = StoredTMBSession(
      schemaVersion: TMBSession.schemaVersion,
      instance: session.instance,
      origin: session.origin.url.absoluteString,
      accountDID: session.accountDID,
      handle: session.handle,
      accessToken: session.accessToken,
      tokenType: session.tokenType,
      expiresAt: session.expiresAt,
      sessionID: session.sessionID,
      proofKey: session.proofKey.rawRepresentation,
      refreshProof: session.refreshProof,
      pdsNonce: session.pdsNonce,
      revision: session.revision
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data: Data
    do { data = try encoder.encode(stored) } catch { throw TMBSessionStoreError.invalidState }

    let directory = fileURL.deletingLastPathComponent()
    try prepareDirectory(directory)
    try validateExistingFileIfPresent()
    let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
    var descriptor = open(
      temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw posixFailure("could not create temporary session state") }
    var removeTemporary = true
    defer {
      if descriptor >= 0 { _ = close(descriptor) }
      if removeTemporary { _ = unlink(temporary.path) }
    }
    guard fchmod(descriptor, mode_t(0o600)) == 0 else {
      throw posixFailure("could not secure temporary session state")
    }
    try writeAll(data, to: descriptor)
    guard fsync(descriptor) == 0, close(descriptor) == 0 else {
      descriptor = -1
      throw posixFailure("could not flush temporary session state")
    }
    descriptor = -1
    guard rename(temporary.path, fileURL.path) == 0 else {
      throw posixFailure("could not replace session state")
    }
    removeTemporary = false
    try validateExistingFileIfPresent()
    let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0)
    guard directoryDescriptor >= 0 else { throw posixFailure("could not open session directory") }
    defer { _ = close(directoryDescriptor) }
    guard fsync(directoryDescriptor) == 0 else { throw posixFailure("could not flush session directory") }
  }

  public func replace(_ session: TMBSession, ifCurrentRevision revision: String) throws -> Bool {
    let lockURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent(".\(fileURL.lastPathComponent).lock")
    try prepareDirectory(lockURL.deletingLastPathComponent())
    let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw posixFailure("could not open session lock") }
    defer {
      _ = flock(descriptor, LOCK_UN)
      _ = close(descriptor)
    }
    guard fchmod(descriptor, mode_t(0o600)) == 0, flock(descriptor, LOCK_EX) == 0 else {
      throw posixFailure("could not lock session state")
    }
    guard try load()?.revision == revision else { return false }
    try write(session)
    return true
  }

  public func clear() throws {
    guard fileURL.isFileURL else { throw failure("location is not a file URL") }
    guard try validateDirectoryIfPresent(fileURL.deletingLastPathComponent()) else { return }
    var info = stat()
    if lstat(fileURL.path, &info) != 0 {
      if errno == ENOENT { return }
      throw posixFailure("could not inspect session state")
    }
    try validateFileMetadata(info)
    guard unlink(fileURL.path) == 0 || errno == ENOENT else {
      throw posixFailure("could not remove session state")
    }
  }

  private func prepareDirectory(_ directory: URL) throws {
    if try validateDirectoryIfPresent(directory) { return }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch { throw failure("could not create session directory") }
    guard try validateDirectoryIfPresent(directory) else {
      throw failure("session directory was not created")
    }
  }

  private func validateDirectoryIfPresent(_ directory: URL) throws -> Bool {
    var info = stat()
    if lstat(directory.path, &info) != 0 {
      if errno == ENOENT { return false }
      throw posixFailure("could not inspect session directory")
    }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid(),
      info.st_mode & mode_t(0o777) == mode_t(0o700)
    else { throw failure("session directory must be owned mode 0700") }
    return true
  }

  private func validateExistingFileIfPresent() throws {
    var info = stat()
    if lstat(fileURL.path, &info) != 0 {
      if errno == ENOENT { return }
      throw posixFailure("could not inspect session state")
    }
    try validateFileMetadata(info)
  }

  private func validateFile(_ descriptor: Int32) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw posixFailure("could not inspect session state") }
    try validateFileMetadata(info)
  }

  private func validateFileMetadata(_ info: stat) throws {
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
      info.st_mode & mode_t(0o777) == mode_t(0o600), info.st_nlink == 1
    else { throw failure("session state must be an owned mode 0600 regular file with one link") }
  }

  private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard var address = bytes.baseAddress else { return }
      var remaining = bytes.count
      while remaining > 0 {
        let count = tmbSessionWrite(descriptor, address, remaining)
        if count < 0 {
          if errno == EINTR { continue }
          throw posixFailure("could not write session state")
        }
        remaining -= count
        address = address.advanced(by: count)
      }
    }
  }

  private func failure(_ message: String) -> TMBSessionStoreError { .unavailable(message) }
  private func posixFailure(_ message: String) -> TMBSessionStoreError {
    .unavailable("\(message): \(String(cString: strerror(errno)))")
  }
}

private struct StoredTMBSession: Codable {
  let schemaVersion: Int
  let instance: String
  let origin: String
  let accountDID: String
  let handle: String
  let accessToken: String
  let tokenType: String
  let expiresAt: Date
  let sessionID: String
  let proofKey: Data
  let refreshProof: Org.Nnabeyang.TmbDefs_ProofRequest
  let pdsNonce: String?
  let revision: String?

  init(
    schemaVersion: Int, instance: String, origin: String, accountDID: String, handle: String,
    accessToken: String, tokenType: String, expiresAt: Date, sessionID: String, proofKey: Data,
    refreshProof: Org.Nnabeyang.TmbDefs_ProofRequest, pdsNonce: String?, revision: String?
  ) {
    self.schemaVersion = schemaVersion
    self.instance = instance
    self.origin = origin
    self.accountDID = accountDID
    self.handle = handle
    self.accessToken = accessToken
    self.tokenType = tokenType
    self.expiresAt = expiresAt
    self.sessionID = sessionID
    self.proofKey = proofKey
    self.refreshProof = refreshProof
    self.pdsNonce = pdsNonce
    self.revision = revision
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    instance = try container.decode(String.self, forKey: .instance)
    origin = try container.decode(String.self, forKey: .origin)
    accountDID = try container.decode(String.self, forKey: .accountDID)
    handle = try container.decode(String.self, forKey: .handle)
    accessToken = try container.decode(String.self, forKey: .accessToken)
    tokenType = try container.decode(String.self, forKey: .tokenType)
    let value = try container.decode(String.self, forKey: .expiresAt)
    guard let date = ISO8601DateFormatter().date(from: value) else {
      throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: container, debugDescription: "invalid date")
    }
    expiresAt = date
    sessionID = try container.decode(String.self, forKey: .sessionID)
    proofKey = try container.decode(Data.self, forKey: .proofKey)
    refreshProof = try container.decode(Org.Nnabeyang.TmbDefs_ProofRequest.self, forKey: .refreshProof)
    pdsNonce = try container.decodeIfPresent(String.self, forKey: .pdsNonce)
    revision = try container.decodeIfPresent(String.self, forKey: .revision)
  }
}

private func tmbSessionWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
  #if canImport(Darwin)
    Darwin.write(descriptor, buffer, count)
  #elseif canImport(Glibc)
    Glibc.write(descriptor, buffer, count)
  #else
    -1
  #endif
}
