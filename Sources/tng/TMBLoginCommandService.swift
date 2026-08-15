import Foundation
import SwiftTangled

struct TMBLoginResult: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let action: String
  let instance: String
  let origin: String
  let accountDID: String
  let handle: String
  let expiresAt: Date

  init(
    action: String, instance: String, origin: String, accountDID: String, handle: String,
    expiresAt: Date
  ) {
    schemaVersion = 1
    self.action = action
    self.instance = instance
    self.origin = origin
    self.accountDID = accountDID
    self.handle = handle
    self.expiresAt = expiresAt
  }
}

struct TMBLoginCommandService: Sendable {
  var formatter: CLIFormatter = .live

  func login(
    identifier: String,
    instance: String,
    browser: any BrowserLauncher,
    json: Bool
  ) async throws -> CLICommandOutput {
    let deviceStore = FileTMBDeviceCredentialStore(
      fileURL: try CLITMBDeviceStore.fileURL(instance: instance))
    guard let registration = try deviceStore.load() else {
      throw TMBClientError.missingDeviceCredentials
    }
    let sessionStore = FileTMBSessionStore(
      fileURL: try CLITMBDeviceStore.sessionFileURL(instance: instance))
    guard try sessionStore.load() == nil else { throw TMBAuthFlowError.sessionAlreadyExists }
    let client = TMBClient(
      origin: registration.origin,
      credentials: registration.credentials,
      credentialsDidChange: { credentials in
        try deviceStore.write(
          TMBDeviceRegistration(
            instance: registration.instance,
            origin: registration.origin,
            credentials: credentials
          ))
      })
    let session = try await TMBAuthFlow(browser: browser).login(
      identifier: identifier,
      registration: registration,
      client: client
    )
    try sessionStore.write(session)
    let result = TMBLoginResult(
      action: "signed-in",
      instance: instance,
      origin: registration.origin.url.absoluteString,
      accountDID: session.accountDID,
      handle: session.handle,
      expiresAt: session.expiresAt
    )
    if json { return CLICommandOutput(stdout: try formatter.json(result)) }
    return CLICommandOutput(
      stdout: "Signed in through TMB instance '\(instance)' as @\(session.handle) (\(session.accountDID)).\n"
    )
  }
}

struct CLITMBAuthBrowserLauncher: BrowserLauncher {
  let noBrowser: Bool
  var systemBrowser: any BrowserLauncher = .system
  var output: @Sendable (String) -> Void = { message in
    FileHandle.standardError.write(Data(message.utf8))
  }

  func open(_ url: URL) async throws {
    if noBrowser {
      output(
        "Open this URL in a browser and keep this command running until authorization completes:\n\(url.absoluteString)\n"
      )
    } else {
      output("Opening browser for TMB OAuth authorization…\n")
      try await systemBrowser.open(url)
    }
  }
}
