import Foundation
import OAuth4Swift

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public final class FileSessionStore: SessionStore {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> StoredSession? {
    guard fileURL.isFileURL else {
      throw failure("session location is not a file URL")
    }
    let directoryURL = fileURL.deletingLastPathComponent()
    guard try validateDirectoryIfPresent(at: directoryURL) else {
      return nil
    }

    let descriptor = try openExistingFile()
    guard descriptor >= 0 else {
      return nil
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try validateSessionFile(descriptor: descriptor)
      let data = try handle.readToEnd() ?? Data()
      return try JSONDecoder().decode(StoredSession.self, from: data)
    } catch let error as TangledError {
      throw error
    } catch let error as DecodingError {
      throw TangledError.decoding(error)
    } catch {
      throw failure("could not read session: \(error.localizedDescription)")
    }
  }

  public func write(_ session: StoredSession) throws {
    guard fileURL.isFileURL else {
      throw failure("session location is not a file URL")
    }
    let data: Data
    do {
      data = try JSONEncoder().encode(session)
    } catch {
      throw TangledError.decoding(error)
    }

    let directoryURL = fileURL.deletingLastPathComponent()
    try prepareDirectory(at: directoryURL)
    try validateExistingSessionFileIfPresent()

    let temporaryURL = directoryURL.appendingPathComponent(
      ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
    )
    var descriptor: Int32 = -1
    var shouldRemoveTemporaryFile = true
    defer {
      if descriptor >= 0 {
        _ = systemClose(descriptor)
      }
      if shouldRemoveTemporaryFile {
        _ = systemUnlink(temporaryURL.path)
      }
    }

    descriptor = systemOpen(
      temporaryURL.path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      mode_t(0o600)
    )
    guard descriptor >= 0 else {
      throw posixFailure("could not create temporary session file")
    }
    guard fchmod(descriptor, mode_t(0o600)) == 0 else {
      throw posixFailure("could not secure temporary session file")
    }
    try writeAll(data, to: descriptor)
    guard systemFSync(descriptor) == 0 else {
      throw posixFailure("could not flush temporary session file")
    }
    guard systemClose(descriptor) == 0 else {
      descriptor = -1
      throw posixFailure("could not close temporary session file")
    }
    descriptor = -1

    guard systemRename(temporaryURL.path, fileURL.path) == 0 else {
      throw posixFailure("could not replace session file")
    }
    shouldRemoveTemporaryFile = false
    try validateExistingSessionFileIfPresent()

    let directoryDescriptor = systemOpen(
      directoryURL.path,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC,
      0
    )
    guard directoryDescriptor >= 0 else {
      throw posixFailure("could not open session directory")
    }
    defer { _ = systemClose(directoryDescriptor) }
    guard systemFSync(directoryDescriptor) == 0 else {
      throw posixFailure("could not flush session directory")
    }
  }

  public func clear() throws {
    guard fileURL.isFileURL else {
      throw failure("session location is not a file URL")
    }
    let directoryURL = fileURL.deletingLastPathComponent()
    guard try validateDirectoryIfPresent(at: directoryURL) else {
      return
    }
    guard try metadata(at: fileURL.path) != nil else {
      return
    }
    try validateExistingSessionFileIfPresent()
    guard systemUnlink(fileURL.path) == 0 else {
      if errno == ENOENT {
        return
      }
      throw posixFailure("could not remove session file")
    }
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

extension FileSessionStore {
  fileprivate func prepareDirectory(at directoryURL: URL) throws {
    if try validateDirectoryIfPresent(at: directoryURL) {
      return
    }
    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw failure("could not create session directory: \(error.localizedDescription)")
    }
    guard try validateDirectoryIfPresent(at: directoryURL) else {
      throw failure("session directory was not created")
    }
  }

  fileprivate func validateDirectoryIfPresent(at directoryURL: URL) throws -> Bool {
    guard let info = try metadata(at: directoryURL.path) else {
      return false
    }
    guard fileType(info.st_mode) == mode_t(S_IFDIR) else {
      throw failure("session directory is not a directory")
    }
    guard info.st_uid == geteuid() else {
      throw failure("session directory is not owned by the current user")
    }
    guard permissions(info.st_mode) == mode_t(0o700) else {
      throw failure("session directory permissions must be 0700")
    }
    return true
  }

  fileprivate func validateExistingSessionFileIfPresent() throws {
    guard let info = try metadata(at: fileURL.path) else {
      return
    }
    guard fileType(info.st_mode) == mode_t(S_IFREG) else {
      throw failure("session file must be a regular file")
    }
    try validateSessionMetadata(info)
  }

  fileprivate func validateSessionFile(descriptor: Int32) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw posixFailure("could not inspect session file")
    }
    guard fileType(info.st_mode) == mode_t(S_IFREG) else {
      throw failure("session file must be a regular file")
    }
    try validateSessionMetadata(info)
  }

  fileprivate func validateSessionMetadata(_ info: stat) throws {
    guard info.st_uid == geteuid() else {
      throw failure("session file is not owned by the current user")
    }
    guard permissions(info.st_mode) == mode_t(0o600) else {
      throw failure("session file permissions must be 0600")
    }
    guard info.st_nlink == 1 else {
      throw failure("session file must not have hard links")
    }
  }

  fileprivate func openExistingFile() throws -> Int32 {
    let descriptor = systemOpen(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
    if descriptor >= 0 {
      return descriptor
    }
    if errno == ENOENT {
      return -1
    }
    throw posixFailure("could not open session file")
  }

  fileprivate func metadata(at path: String) throws -> stat? {
    var info = stat()
    let result = path.withCString { lstat($0, &info) }
    if result == 0 {
      return info
    }
    if errno == ENOENT {
      return nil
    }
    throw posixFailure("could not inspect session storage")
  }

  fileprivate func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard var address = rawBuffer.baseAddress else {
        return
      }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let written = systemWrite(descriptor, address, remaining)
        if written < 0 {
          if errno == EINTR {
            continue
          }
          throw posixFailure("could not write temporary session file")
        }
        remaining -= written
        address = address.advanced(by: written)
      }
    }
  }

  fileprivate func failure(_ message: String) -> TangledError {
    TangledError.sessionStoreFailure(message)
  }

  fileprivate func posixFailure(_ message: String) -> TangledError {
    let code = errno
    return failure("\(message): \(String(cString: strerror(code)))")
  }

  fileprivate func fileType(_ mode: mode_t) -> mode_t {
    mode & mode_t(S_IFMT)
  }

  fileprivate func permissions(_ mode: mode_t) -> mode_t {
    mode & mode_t(0o777)
  }
}

private func systemOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
  path.withCString { open($0, flags, mode) }
}

private func systemClose(_ descriptor: Int32) -> Int32 {
  close(descriptor)
}

private func systemWrite(
  _ descriptor: Int32,
  _ buffer: UnsafeRawPointer,
  _ count: Int
) -> Int {
  write(descriptor, buffer, count)
}

private func systemFSync(_ descriptor: Int32) -> Int32 {
  fsync(descriptor)
}

private func systemRename(_ source: String, _ destination: String) -> Int32 {
  source.withCString { sourcePath in
    destination.withCString { destinationPath in
      rename(sourcePath, destinationPath)
    }
  }
}

private func systemUnlink(_ path: String) -> Int32 {
  path.withCString { unlink($0) }
}
