import Foundation
import Testing

@testable import SwiftTangled

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Suite struct FileSessionStoreTests {
  @Test func roundTripOverwriteAndClear() throws {
    let fixture = try FileStoreFixture()
    let store = FileSessionStore(fileURL: fixture.fileURL)

    #expect(try store.load() == nil)

    try store.write(try SessionStoreTestHelpers.makeStoredSession(handle: "alice.test"))
    #expect(try #require(try store.load()).handle == "alice.test")

    try store.write(try SessionStoreTestHelpers.makeStoredSession(handle: "bob.test"))
    #expect(try #require(try store.load()).handle == "bob.test")

    try store.clear()
    try store.clear()
    #expect(try store.load() == nil)
  }

  @Test func createsPrivateStorageAndLeavesNoTemporaryFiles() throws {
    let fixture = try FileStoreFixture()
    let store = FileSessionStore(fileURL: fixture.fileURL)

    try store.write(try SessionStoreTestHelpers.makeStoredSession())

    #expect(try permissions(at: fixture.directoryURL) == 0o700)
    #expect(try permissions(at: fixture.fileURL) == 0o600)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.directoryURL.path)
        == ["session.json"]
    )
  }

  @Test func OAuthPersistenceUpdatesAndClearsStoredTokenState() throws {
    let fixture = try FileStoreFixture()
    let store = FileSessionStore(fileURL: fixture.fileURL)
    try store.write(try SessionStoreTestHelpers.makeStoredSession(accessToken: "old"))
    let refreshed = try SessionStoreTestHelpers.makeStoredSession(accessToken: "new")

    store.save(refreshed.archive.tokenState)

    #expect(try #require(try store.load()).archive.tokenState.accessToken.value == "new")
    store.save(nil)
    #expect(try store.load() == nil)
  }

  @Test func rejectsCorruptJSON() throws {
    let fixture = try FileStoreFixture()
    try fixture.createDirectory()
    try Data("not-json".utf8).write(to: fixture.fileURL)
    try setPermissions(0o600, at: fixture.fileURL)
    let store = FileSessionStore(fileURL: fixture.fileURL)

    #expect(throws: TangledError.self) {
      _ = try store.load()
    }
  }

  @Test func rejectsUnsafeDirectoryAndFilePermissions() throws {
    let unsafeDirectory = try FileStoreFixture()
    try unsafeDirectory.createDirectory()
    try setPermissions(0o755, at: unsafeDirectory.directoryURL)
    #expect(throws: TangledError.self) {
      try FileSessionStore(fileURL: unsafeDirectory.fileURL)
        .write(try SessionStoreTestHelpers.makeStoredSession())
    }

    let unsafeFile = try FileStoreFixture()
    let store = FileSessionStore(fileURL: unsafeFile.fileURL)
    try store.write(try SessionStoreTestHelpers.makeStoredSession())
    try setPermissions(0o644, at: unsafeFile.fileURL)
    #expect(throws: TangledError.self) {
      _ = try store.load()
    }
  }

  @Test func rejectsFileAndDirectorySymlinks() throws {
    let fileSymlink = try FileStoreFixture()
    try fileSymlink.createDirectory()
    let target = fileSymlink.rootURL.appendingPathComponent("target")
    try Data("target".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: fileSymlink.fileURL,
      withDestinationURL: target
    )
    #expect(throws: TangledError.self) {
      _ = try FileSessionStore(fileURL: fileSymlink.fileURL).load()
    }

    let directorySymlink = try FileStoreFixture()
    let actualDirectory = directorySymlink.rootURL.appendingPathComponent("actual")
    try FileManager.default.createDirectory(
      at: actualDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.createSymbolicLink(
      at: directorySymlink.directoryURL,
      withDestinationURL: actualDirectory
    )
    #expect(throws: TangledError.self) {
      try FileSessionStore(fileURL: directorySymlink.fileURL)
        .write(try SessionStoreTestHelpers.makeStoredSession())
    }
  }

  @Test func rejectsHardLinksWithoutReplacingExistingSession() throws {
    let fixture = try FileStoreFixture()
    let store = FileSessionStore(fileURL: fixture.fileURL)
    try store.write(try SessionStoreTestHelpers.makeStoredSession(handle: "alice.test"))
    let hardLink = fixture.rootURL.appendingPathComponent("session-link.json")
    try FileManager.default.linkItem(at: fixture.fileURL, to: hardLink)
    let original = try Data(contentsOf: fixture.fileURL)

    #expect(throws: TangledError.self) {
      try store.write(try SessionStoreTestHelpers.makeStoredSession(handle: "bob.test"))
    }
    #expect(try Data(contentsOf: fixture.fileURL) == original)
  }
}

private final class FileStoreFixture {
  let rootURL: URL
  let directoryURL: URL
  let fileURL: URL

  init() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("swift-tangled-file-session-store")
      .appendingPathComponent(UUID().uuidString)
    directoryURL = rootURL.appendingPathComponent("tng")
    fileURL = directoryURL.appendingPathComponent("session.json")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: rootURL)
  }

  func createDirectory() throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
  }
}

private func permissions(at url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try #require(attributes[.posixPermissions] as? Int)
}

private func setPermissions(_ permissions: Int32, at url: URL) throws {
  guard chmod(url.path, mode_t(permissions)) == 0 else {
    throw CocoaError(.fileWriteNoPermission)
  }
}
