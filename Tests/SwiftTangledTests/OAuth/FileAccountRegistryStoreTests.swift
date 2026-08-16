import Foundation
import Testing

@testable import SwiftTangled

@Suite struct FileAccountRegistryStoreTests {
  @Test func writesModeRestrictedRegistryAtomically() throws {
    try withTemporaryDirectory { directory in
      let accountsDirectory = directory.appendingPathComponent("accounts")
      let file = accountsDirectory.appendingPathComponent("registry.json")
      let store = FileAccountRegistryStore(fileURL: file)
      let accounts = [AccountSession(did: "did:plc:one", handle: "one.test", isActive: true)]

      try store.write(accounts)

      #expect(try store.load() == accounts)
      #expect(permissions(of: accountsDirectory) == 0o700)
      #expect(permissions(of: file) == 0o600)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: accountsDirectory.path).sorted()
          == ["registry.json"])
    }
  }

  @Test func rejectsSymbolicLinkRegistry() throws {
    try withTemporaryDirectory { directory in
      let accountsDirectory = directory.appendingPathComponent("accounts")
      try FileManager.default.createDirectory(
        at: accountsDirectory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let target = directory.appendingPathComponent("target.json")
      try Data("{}".utf8).write(to: target)
      let registry = accountsDirectory.appendingPathComponent("registry.json")
      try FileManager.default.createSymbolicLink(at: registry, withDestinationURL: target)

      #expect(throws: (any Error).self) {
        try FileAccountRegistryStore(fileURL: registry).write([])
      }
    }
  }

  private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
  }

  private func permissions(of url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
  }
}
