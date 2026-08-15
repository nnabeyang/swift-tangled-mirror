import ArgumentParser
import Foundation
import SwiftTangled
import Testing

@testable import tng

@Test func authAgentTMBCommandsParseNamedInstancesAndJSON() throws {
  let enroll = try AuthAgentTMBEnrollCommand.parse([
    "--origin", "https://tmb.example",
    "--name", "validation-mac",
    "--instance", "reporting",
    "--json",
  ])
  #expect(enroll.origin == "https://tmb.example")
  #expect(enroll.name == "validation-mac")
  #expect(enroll.options.instance == "reporting")
  #expect(enroll.options.json)

  let status = try AuthAgentTMBStatusCommand.parse([])
  #expect(status.options.resolvedInstance == "default")
  let revoke = try AuthAgentTMBRevokeCommand.parse(["--instance", "reporting", "--yes"])
  #expect(revoke.yes)
}

@Test func authAgentTMBCommandsRejectInvalidInputs() {
  #expect(throws: (any Error).self) {
    var command = try AuthAgentTMBEnrollCommand.parse([
      "--origin", "http://tmb.example",
      "--name", "device",
    ])
    try command.validate()
  }
  #expect(throws: (any Error).self) {
    var command = try AuthAgentTMBStatusCommand.parse(["--instance", "CI_report"])
    try command.validate()
  }
}

@Suite struct TMBDeviceCommandServiceTests {
  @Test func enrollStoresCredentialsAndNeverPrintsSecrets() async throws {
    let store = MemoryTMBDeviceStore()
    let recorder = TMBCommandRecorder()
    let service = makeService(store: store, recorder: recorder)

    let output = try await service.enroll(
      instance: "reporting",
      origin: "https://TMB.EXAMPLE/",
      name: "validation-mac",
      secret: "one-time-secret",
      json: false
    )

    let registration = try #require(store.registration)
    #expect(registration.origin.url.absoluteString == "https://tmb.example")
    #expect(registration.credentials.deviceID == "device-1")
    #expect(output.stdout.contains("device-1"))
    #expect(!output.stdout.contains("one-time-secret"))
    #expect(!output.stdout.contains("nonce-1"))
    #expect(await recorder.enrollmentSecret == "one-time-secret")
  }

  @Test func enrollRejectsExistingStateBeforeSendingSecret() async throws {
    let store = MemoryTMBDeviceStore(
      registration: try registration()
    )
    let recorder = TMBCommandRecorder()
    let service = makeService(store: store, recorder: recorder)

    await #expect(throws: CLICommandError.self) {
      _ = try await service.enroll(
        instance: "reporting",
        origin: "https://tmb.example",
        name: "device",
        secret: "secret",
        json: false
      )
    }
    #expect(await recorder.enrollmentSecret == nil)
  }

  @Test func statusReportsMissingAndConfiguredStateAsVersionedJSON() throws {
    let store = MemoryTMBDeviceStore()
    let service = makeService(store: store)
    let missing = try service.status(instance: "reporting", json: true)
    let missingResult = try JSONDecoder().decode(
      TMBDeviceCommandResult.self,
      from: Data(missing.stdout.utf8)
    )
    #expect(missingResult.schemaVersion == 1)
    #expect(!missingResult.configured)

    store.registration = try registration()
    let configured = try service.status(instance: "reporting", json: true)
    #expect(configured.stdout.contains("device-1"))
    #expect(!configured.stdout.contains("nonce-1"))
  }

  @Test func revokeRequiresConfirmationAndClearsOnlyAfterSuccess() async throws {
    let cancelledStore = MemoryTMBDeviceStore(registration: try registration())
    let cancelled = makeService(
      store: cancelledStore,
      inputIsTerminal: true,
      confirmation: false
    )
    let cancelledOutput = try await cancelled.revoke(
      instance: "reporting",
      confirmed: false,
      json: false
    )
    #expect(cancelledOutput.stdout == "Revocation cancelled.\n")
    #expect(cancelledStore.registration != nil)

    let failedStore = MemoryTMBDeviceStore(registration: try registration())
    let failed = makeService(store: failedStore, revokeResult: false)
    await #expect(throws: TMBClientError.invalidResponse) {
      _ = try await failed.revoke(instance: "reporting", confirmed: true, json: false)
    }
    #expect(failedStore.registration != nil)

    let successfulStore = MemoryTMBDeviceStore(registration: try registration())
    let successful = makeService(store: successfulStore)
    let output = try await successful.revoke(
      instance: "reporting",
      confirmed: true,
      json: false
    )
    #expect(output.stdout.contains("device-1"))
    #expect(successfulStore.registration == nil)
  }

  @Test func revokeRequiresYesWhenInputIsNotTerminal() async throws {
    let store = MemoryTMBDeviceStore(registration: try registration())
    let service = makeService(store: store, inputIsTerminal: false)
    await #expect(throws: ValidationError.self) {
      _ = try await service.revoke(instance: "reporting", confirmed: false, json: false)
    }
    #expect(store.registration != nil)
  }

  @Test func defaultStorePathsAreInstanceScoped() throws {
    let url = try CLITMBDeviceStore.fileURL(
      instance: "reporting",
      environment: ["HOME": "/Users/worker", "XDG_STATE_HOME": "/state"]
    )
    #if os(macOS)
      #expect(url.path == "/Users/worker/Library/Application Support/tng/tmb/reporting/device.json")
    #else
      #expect(url.path == "/state/tng/tmb/reporting/device.json")
    #endif
  }
}

private func makeService(
  store: MemoryTMBDeviceStore,
  recorder: TMBCommandRecorder = TMBCommandRecorder(),
  revokeResult: Bool = true,
  inputIsTerminal: Bool = true,
  confirmation: Bool = true
) -> TMBDeviceCommandService {
  TMBDeviceCommandService(
    formatter: .plain,
    dependencies: TMBDeviceCommandDependencies(
      store: { _ in store },
      enroll: { _, _, secret in
        await recorder.record(secret: secret)
        return TMBDeviceCredentials(
          deviceID: "device-1",
          nonce: "nonce-1",
          proofKey: TMBProofKey()
        )
      },
      revoke: { _, _ in revokeResult },
      inputIsTerminal: { inputIsTerminal },
      confirmRevocation: { _ in confirmation }
    )
  )
}

private func registration() throws -> TMBDeviceRegistration {
  try TMBDeviceRegistration(
    instance: "reporting",
    origin: TMBOrigin("https://tmb.example"),
    credentials: TMBDeviceCredentials(
      deviceID: "device-1",
      nonce: "nonce-1",
      proofKey: TMBProofKey()
    )
  )
}

private final class MemoryTMBDeviceStore: TMBDeviceCredentialStoring, @unchecked Sendable {
  var registration: TMBDeviceRegistration?

  init(registration: TMBDeviceRegistration? = nil) {
    self.registration = registration
  }

  func load() throws -> TMBDeviceRegistration? { registration }
  func write(_ registration: TMBDeviceRegistration) throws { self.registration = registration }
  func clear() throws { registration = nil }
}

private actor TMBCommandRecorder {
  private(set) var enrollmentSecret: String?

  func record(secret: String) {
    enrollmentSecret = secret
  }
}
