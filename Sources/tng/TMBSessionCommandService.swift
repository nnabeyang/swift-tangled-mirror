import Foundation
import SwiftAtproto
import SwiftTangled

struct TMBVerificationResult: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let action: String
  let instance: String
  let accountDID: String
  let handle: String
  let refreshed: Bool
  let directPDSRequest: Bool

  init(instance: String, accountDID: String, handle: String, refreshed: Bool) {
    schemaVersion = 1
    action = "verified"
    self.instance = instance
    self.accountDID = accountDID
    self.handle = handle
    self.refreshed = refreshed
    directPDSRequest = true
  }
}

struct TMBLogoutResult: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let action: String
  let instance: String
  let accountDID: String

  init(instance: String, accountDID: String) {
    schemaVersion = 1
    action = "signed-out"
    self.instance = instance
    self.accountDID = accountDID
  }
}

struct TMBSessionCommandService: Sendable {
  var formatter: CLIFormatter = .live

  func verify(instance: String, refresh: Bool, json: Bool) async throws -> CLICommandOutput {
    let context = try liveContext(instance: instance)
    if refresh { try await context.agent.forceRefresh() }
    let data = try await context.agent.response(
      XRPCRequestComponents(
        nsId: "com.atproto.server.getSession",
        queryItems: [], headers: [:], method: .get, body: nil))
    let response = try JSONDecoder().decode(TMBPDSSession.self, from: data)
    guard response.did == context.session.accountDID else {
      throw TMBSessionAgentError.invalidResponse
    }
    let result = TMBVerificationResult(
      instance: instance,
      accountDID: context.session.accountDID,
      handle: context.session.handle,
      refreshed: refresh)
    if json { return CLICommandOutput(stdout: try formatter.json(result)) }
    return CLICommandOutput(
      stdout:
        "Verified direct PDS authentication for @\(context.session.handle) through TMB instance '\(instance)'\(refresh ? " after refresh" : "").\n"
    )
  }

  func logout(instance: String, json: Bool) async throws -> CLICommandOutput {
    let sessionStore = FileTMBSessionStore(
      fileURL: try CLITMBDeviceStore.sessionFileURL(instance: instance))
    guard let session = try sessionStore.load() else { throw TMBSessionAgentError.sessionMissing }
    let deviceStore = FileTMBDeviceCredentialStore(
      fileURL: try CLITMBDeviceStore.fileURL(instance: instance))
    guard let registration = try deviceStore.load() else {
      throw TMBClientError.missingDeviceCredentials
    }
    let client = liveTMBClient(registration: registration, store: deviceStore)
    guard try await client.revoke(sessionID: session.sessionID) else {
      throw TMBSessionAgentError.sessionRevoked
    }
    try sessionStore.clear()
    let result = TMBLogoutResult(instance: instance, accountDID: session.accountDID)
    if json { return CLICommandOutput(stdout: try formatter.json(result)) }
    return CLICommandOutput(
      stdout: "Signed out @\(session.handle) from TMB instance '\(instance)'.\n")
  }

  private func liveContext(instance: String) throws -> (
    session: TMBSession, agent: TMBSessionAgent
  ) {
    let sessionStore = FileTMBSessionStore(
      fileURL: try CLITMBDeviceStore.sessionFileURL(instance: instance))
    guard let session = try sessionStore.load() else { throw TMBSessionAgentError.sessionMissing }
    let deviceStore = FileTMBDeviceCredentialStore(
      fileURL: try CLITMBDeviceStore.fileURL(instance: instance))
    guard let registration = try deviceStore.load(), registration.origin == session.origin else {
      throw TMBClientError.missingDeviceCredentials
    }
    let client = liveTMBClient(registration: registration, store: deviceStore)
    return (
      session,
      TMBSessionAgent(session: session, store: sessionStore, tmb: client)
    )
  }

  private func liveTMBClient(
    registration: TMBDeviceRegistration,
    store: FileTMBDeviceCredentialStore
  ) -> TMBClient {
    TMBClient(
      origin: registration.origin,
      credentials: registration.credentials,
      credentialsDidChange: { credentials in
        try store.write(
          TMBDeviceRegistration(
            instance: registration.instance,
            origin: registration.origin,
            credentials: credentials))
      })
  }
}

private struct TMBPDSSession: Decodable {
  let did: String
}
