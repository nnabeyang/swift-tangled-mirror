import Foundation
import Testing

@testable import SwiftTangled

@Suite struct TMBDeviceCredentialStoreTests {
  @Test func writesAndLoadsOwnerOnlyDeviceState() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let key = TMBProofKey()
    let registration = try fixture.registration(
      deviceID: "device-1",
      nonce: "nonce-1",
      key: key
    )

    try fixture.store.write(registration)
    let loaded = try #require(try fixture.store.load())

    #expect(loaded.instance == "reporting")
    #expect(loaded.origin.url.absoluteString == "https://tmb.example")
    #expect(loaded.credentials.deviceID == "device-1")
    #expect(loaded.credentials.nonce == "nonce-1")
    #expect(loaded.credentials.proofKey.rawRepresentation == key.rawRepresentation)
    #expect(try permissions(fixture.directoryURL) == 0o700)
    #expect(try permissions(fixture.fileURL) == 0o600)
  }

  @Test func atomicallyReplacesExistingDeviceState() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.store.write(try fixture.registration(deviceID: "first", nonce: nil))
    try fixture.store.write(try fixture.registration(deviceID: "second", nonce: "next"))

    let loaded = try #require(try fixture.store.load())
    #expect(loaded.credentials.deviceID == "second")
    #expect(loaded.credentials.nonce == "next")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.directoryURL.path).sorted()
        == ["device.json"]
    )
  }

  @Test func clearIsIdempotent() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.store.write(try fixture.registration())

    try fixture.store.clear()
    try fixture.store.clear()

    #expect(try fixture.store.load() == nil)
  }

  @Test func rejectsWrongPermissionsSymlinksAndHardLinks() throws {
    let permissionsFixture = try Fixture()
    defer { permissionsFixture.remove() }
    try permissionsFixture.store.write(try permissionsFixture.registration())
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: permissionsFixture.fileURL.path
    )
    #expect(throws: TMBDeviceCredentialStoreError.self) {
      _ = try permissionsFixture.store.load()
    }

    let symlinkFixture = try Fixture()
    defer { symlinkFixture.remove() }
    try FileManager.default.createDirectory(
      at: symlinkFixture.directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let target = symlinkFixture.rootURL.appendingPathComponent("target")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    try FileManager.default.createSymbolicLink(
      at: symlinkFixture.fileURL,
      withDestinationURL: target
    )
    #expect(throws: TMBDeviceCredentialStoreError.self) {
      _ = try symlinkFixture.store.load()
    }

    let hardLinkFixture = try Fixture()
    defer { hardLinkFixture.remove() }
    try hardLinkFixture.store.write(try hardLinkFixture.registration())
    try FileManager.default.linkItem(
      at: hardLinkFixture.fileURL,
      to: hardLinkFixture.rootURL.appendingPathComponent("linked-device")
    )
    #expect(throws: TMBDeviceCredentialStoreError.self) {
      _ = try hardLinkFixture.store.load()
    }
  }

  @Test func rejectsInvalidAndUnsupportedStoredStateWithoutLeakingIt() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeRaw(
      #"{"schemaVersion":99,"instance":"reporting","origin":"https://tmb.example","deviceID":"secret-device","proofKey":"c2VjcmV0"}"#
    )

    do {
      _ = try fixture.store.load()
      Issue.record("unsupported state must fail")
    } catch {
      #expect(error as? TMBDeviceCredentialStoreError == .unsupportedSchemaVersion)
      #expect(!error.localizedDescription.contains("secret-device"))
      #expect(!error.localizedDescription.contains("c2VjcmV0"))
    }
  }

  @Test func validatesNamedInstances() {
    for value in ["default", "reporting", "ci-2"] {
      #expect(TMBDeviceRegistration.validInstance(value))
    }
    for value in ["", "2ci", "CI", "ci_report", String(repeating: "a", count: 33)] {
      #expect(!TMBDeviceRegistration.validInstance(value))
    }
  }
}

private struct Fixture {
  let rootURL: URL
  let directoryURL: URL
  let fileURL: URL
  let store: FileTMBDeviceCredentialStore

  init() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("tmb-device-store-tests-\(UUID().uuidString)")
    directoryURL = rootURL.appendingPathComponent("reporting")
    fileURL = directoryURL.appendingPathComponent("device.json")
    store = FileTMBDeviceCredentialStore(fileURL: fileURL)
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
  }

  func registration(
    deviceID: String = "device",
    nonce: String? = "nonce",
    key: TMBProofKey = TMBProofKey()
  ) throws -> TMBDeviceRegistration {
    try TMBDeviceRegistration(
      instance: "reporting",
      origin: TMBOrigin("https://tmb.example"),
      credentials: TMBDeviceCredentials(deviceID: deviceID, nonce: nonce, proofKey: key)
    )
  }

  func writeRaw(_ value: String) throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directoryURL.path
    )
    try Data(value.utf8).write(to: fileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private func permissions(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try #require(attributes[.posixPermissions] as? Int)
}
