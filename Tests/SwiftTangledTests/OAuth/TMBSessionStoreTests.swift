import Foundation
import TangledLexicons
import Testing

@testable import SwiftTangled

@Suite struct TMBSessionStoreTests {
  @Test func writesLoadsReplacesAndClearsOwnerOnlyState() throws {
    let fixture = try TMBSessionFixture()
    defer { fixture.remove() }
    let first = try fixture.session(token: "token-one")
    try fixture.store.write(first)
    var loaded = try #require(try fixture.store.load())
    #expect(loaded.accessToken == "token-one")
    #expect(loaded.proofKey.rawRepresentation == first.proofKey.rawRepresentation)
    #expect(try tmbSessionPermissions(fixture.directoryURL) == 0o700)
    #expect(try tmbSessionPermissions(fixture.fileURL) == 0o600)

    try fixture.store.write(try fixture.session(token: "token-two"))
    loaded = try #require(try fixture.store.load())
    #expect(loaded.accessToken == "token-two")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directoryURL.path) == ["session.json"])

    try fixture.store.clear()
    try fixture.store.clear()
    #expect(try fixture.store.load() == nil)
  }

  @Test func rejectsWrongPermissionsSymlinkAndHardLink() throws {
    let wrongMode = try TMBSessionFixture()
    defer { wrongMode.remove() }
    try wrongMode.store.write(try wrongMode.session())
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wrongMode.fileURL.path)
    #expect(throws: TMBSessionStoreError.self) { _ = try wrongMode.store.load() }

    let symlink = try TMBSessionFixture()
    defer { symlink.remove() }
    try FileManager.default.createDirectory(
      at: symlink.directoryURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let target = symlink.rootURL.appendingPathComponent("target")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    try FileManager.default.createSymbolicLink(at: symlink.fileURL, withDestinationURL: target)
    #expect(throws: TMBSessionStoreError.self) { _ = try symlink.store.load() }

    let hardLink = try TMBSessionFixture()
    defer { hardLink.remove() }
    try hardLink.store.write(try hardLink.session())
    try FileManager.default.linkItem(
      at: hardLink.fileURL, to: hardLink.rootURL.appendingPathComponent("linked-session"))
    #expect(throws: TMBSessionStoreError.self) { _ = try hardLink.store.load() }
  }

  @Test func conditionalReplacementRejectsAStaleProcessSnapshot() throws {
    let fixture = try TMBSessionFixture()
    defer { fixture.remove() }
    let first = try fixture.session(token: "token-one")
    let second = try fixture.session(token: "token-two")
    let stale = try fixture.session(token: "stale-token")
    try fixture.store.write(first)

    #expect(try fixture.store.replace(second, ifCurrentRevision: first.revision))
    #expect(try !fixture.store.replace(stale, ifCurrentRevision: first.revision))
    #expect(try fixture.store.load()?.accessToken == "token-two")
  }
}

private struct TMBSessionFixture {
  let rootURL: URL
  let directoryURL: URL
  let fileURL: URL
  let store: FileTMBSessionStore

  init() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("tmb-session-tests-\(UUID().uuidString)", isDirectory: true)
    directoryURL = rootURL.appendingPathComponent("instance", isDirectory: true)
    fileURL = directoryURL.appendingPathComponent("session.json")
    store = FileTMBSessionStore(fileURL: fileURL)
  }

  func session(token: String = "access-token") throws -> TMBSession {
    try TMBSession(
      instance: "validation",
      origin: TMBOrigin("https://tmb.example"),
      accountDID: "did:plc:alice",
      handle: "alice.example",
      accessToken: token,
      tokenType: "DPoP",
      expiresAt: Date(timeIntervalSince1970: 2_000),
      sessionID: "session-one",
      proofKey: TMBProofKey(),
      refreshProof: .init(
        endpoint: .init(rawValue: "https://issuer.example/token"), nonce: "nonce")
    )
  }

  func remove() { try? FileManager.default.removeItem(at: rootURL) }
}

private func tmbSessionPermissions(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
