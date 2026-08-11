import ArgumentParser
import Foundation
import SwiftTangled
import Testing

@testable import tng

@Test func authAgentServiceCommandsParseNamedInstancesAndJSON() throws {
  let install = try AuthAgentServiceInstallCommand.parse([
    "--session-file", "/Users/worker/session.json",
    "--socket", "/Users/worker/agent.sock",
    "--profile", "ci-reporting",
    "--instance", "reporting",
    "--executable", "/Applications/tng",
    "--json",
  ])
  #expect(install.sessionFile == "/Users/worker/session.json")
  #expect(install.socket == "/Users/worker/agent.sock")
  #expect(install.instance == "reporting")
  #expect(install.json)

  let status = try AuthAgentServiceStatusCommand.parse(["--instance", "reporting", "--json"])
  #expect(status.options.instance == "reporting")
  #expect(status.options.json)
}

@Test func authAgentServiceInstallRejectsRelativePathsAndProfiles() {
  #expect(throws: (any Error).self) {
    var command = try AuthAgentServiceInstallCommand.parse([
      "--session-file", "session.json",
      "--socket", "/Users/worker/agent.sock",
      "--profile", "ci-reporting",
    ])
    try command.validate()
  }
  #expect(throws: (any Error).self) {
    var command = try AuthAgentServiceInstallCommand.parse([
      "--session-file", "/Users/worker/session.json",
      "--socket", "/Users/worker/agent.sock",
      "--profile", "default",
    ])
    try command.validate()
  }
}

@Test func authAgentServicePropertyListUsesPrivateNamedPathsWithoutSessionContents() throws {
  let identity = AuthAgentLaunchAgentService.Identity(
    label: "sh.tangled.tng.auth-agent.reporting",
    homeDirectory: "/Users/worker",
    logDirectory: "/Users/worker/Library/Logs/tng/auth-agent/reporting",
    plistPath: "/Users/worker/Library/LaunchAgents/sh.tangled.tng.auth-agent.reporting.plist"
  )
  let plist = AuthAgentLaunchAgentService.propertyList(
    executable: "/Applications/tng",
    configuration: AuthAgentServiceConfiguration(
      sessionFile: "/Users/worker/session.json",
      socketPath: "/Users/worker/agent.sock",
      profile: .ciReporting,
      maximumBodyBytes: 1024,
      maximumJobUploadBytes: 2048
    ),
    identity: identity
  )

  #expect(plist["Label"] as? String == "sh.tangled.tng.auth-agent.reporting")
  #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
  #expect(plist["RunAtLoad"] as? Bool == true)
  #expect(plist["Umask"] as? String == "0077")
  #expect(
    plist["EnvironmentVariables"] as? [String: String]
      == ["TNG_SESSION_FILE": "/Users/worker/session.json"]
  )
  let encoded = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
  let text = String(decoding: encoded, as: UTF8.self)
  #expect(!text.contains("access-token"))
  #expect(!text.contains("refresh-token"))
  #expect(!text.contains("dpop"))
}

@Test func authAgentServiceStatusDistinguishesNotInstalledStoppedAndRunning() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("tng-auth-agent-service-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("Library/LaunchAgents"),
    withIntermediateDirectories: true
  )
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
  defer { try? FileManager.default.removeItem(at: root) }

  var service = AuthAgentLaunchAgentService(
    homeDirectory: root.path,
    userID: 501,
    commandRunner: StubAuthAgentCommandRunner(status: 1, stdout: ""),
    probe: { _ in
      AuthAgentServiceProbe(
        accountDID: "did:plc:ci",
        handle: "ci.example",
        profile: .ciReporting,
        protocolVersion: AuthAgentProtocol.version
      )
    }
  )
  let absent = try await service.status(instance: "reporting")
  #expect(absent.state == .notInstalled)

  let identity = AuthAgentLaunchAgentService.Identity(
    label: "sh.tangled.tng.auth-agent.reporting",
    homeDirectory: root.path,
    logDirectory: root.appendingPathComponent("logs").path,
    plistPath: root.appendingPathComponent(
      "Library/LaunchAgents/sh.tangled.tng.auth-agent.reporting.plist"
    ).path
  )
  let plist = AuthAgentLaunchAgentService.propertyList(
    executable: "/Applications/tng",
    configuration: AuthAgentServiceConfiguration(
      sessionFile: root.appendingPathComponent("missing-session.json").path,
      socketPath: root.appendingPathComponent("agent.sock").path,
      profile: .ciReporting,
      maximumBodyBytes: 1024,
      maximumJobUploadBytes: 2048
    ),
    identity: identity
  )
  let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
  try data.write(to: URL(fileURLWithPath: identity.plistPath))

  let stopped = try await service.status(instance: "reporting")
  #expect(stopped.state == .stopped)
  #expect(stopped.sessionState == .missing)
  #expect(stopped.socketState == .unavailable)

  service.commandRunner = StubAuthAgentCommandRunner(
    status: 0,
    stdout: "state = running\npid = 1234\n"
  )
  let running = try await service.status(instance: "reporting")
  #expect(running.state == .running)
  #expect(running.pid == 1234)
  #expect(running.socketState == .available)
  #expect(running.handle == "ci.example")
}

@Test func authAgentServiceRejectsInvalidInstanceNames() {
  #expect(throws: AuthAgentLaunchAgentServiceError.invalidInstance) {
    _ = try AuthAgentLaunchAgentService.label(instance: "CI_reporting")
  }
}

private struct StubAuthAgentCommandRunner: AuthAgentSystemCommandRunning {
  var status: Int32
  var stdout: String

  func run(executable: String, arguments: [String]) throws -> AuthAgentSystemCommandOutput {
    AuthAgentSystemCommandOutput(status: status, stdout: stdout, stderr: "")
  }
}
