import Foundation
import SwiftTangled
import Testing

@testable import tng

@Suite struct AuthGitCommandTests {
  @Test func parsesSetupGitOptionsAndCredentialCommandIsHidden() throws {
    let setup = try AuthSetupGitCommand.parse([
      "--remote", "upstream", "--dry-run", "--replace-existing-helper", "--json",
    ])
    #expect(setup.remote == "upstream")
    #expect(setup.dryRun)
    #expect(setup.replaceExistingHelper)
    #expect(setup.json)

    let helper = try AuthGitCredentialCommand.parse(["get"])
    #expect(helper.operation == "get")
    #expect(!AuthGitCredentialCommand.configuration.shouldDisplay)
  }

  @Test func parsesGitCredentialProtocolWithoutTreatingEqualsAsSeparatorTwice() {
    let request = parseGitCredentialRequest(
      "protocol=https\nhost=knot.example\npath=did:plc:repo\npassword=a=b\n\n")
    #expect(request.protocolName == "https")
    #expect(request.host == "knot.example")
    #expect(request.path == "did:plc:repo")
  }

  @Test func dryRunPinsResolvedAccountWithoutMutatingGit() async throws {
    let git = RecordingGit { arguments in
      switch arguments {
      case ["remote", "get-url", "--all", "origin"],
        ["remote", "get-url", "--push", "--all", "origin"]:
        GitProcessResult(status: 0, stdout: "git@knot.example:did:plc:repo\n", stderr: "")
      case let value where value.starts(with: ["config", "--local", "--get-all"]),
        let value where value.starts(with: ["config", "--local", "--get"]):
        GitProcessResult(status: 1, stdout: "", stderr: "")
      default:
        GitProcessResult(status: 99, stdout: "", stderr: "unexpected mutation")
      }
    }
    let result = try await makeService(git: git).setup(
      remote: "origin", dryRun: true, replaceExistingHelper: false, explicitAccount: nil)

    #expect(result.dryRun)
    #expect(result.changed)
    #expect(result.accountDID == "did:plc:alice")
    #expect(result.url == "https://knot.example/did:plc:repo/")
    #expect(!git.commands().contains { $0.contains("set-url") })
  }

  @Test func rejectsMultipleRemoteURLsBeforeAuthentication() async {
    let git = RecordingGit { arguments in
      let output = arguments.contains("--push") ? "one\n" : "one\ntwo\n"
      return GitProcessResult(status: 0, stdout: output, stderr: "")
    }
    await #expect(throws: CLICommandError.self) {
      try await makeService(git: git).setup(
        remote: "origin", dryRun: false, replaceExistingHelper: false, explicitAccount: nil)
    }
  }

  @Test func configuresRealRepositoryIdempotentlyAndRejectsHelperConflict() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = DirectoryGit(directory: directory)
    #expect(git.run(["init"]).status == 0)
    #expect(
      git.run(["remote", "add", "origin", "git@knot.example:did:plc:repo"]).status == 0)
    let service = makeService(git: git.recording)

    let first = try await service.setup(
      remote: "origin", dryRun: false, replaceExistingHelper: false, explicitAccount: nil)
    let second = try await service.setup(
      remote: "origin", dryRun: false, replaceExistingHelper: false, explicitAccount: nil)

    #expect(first.changed)
    #expect(!second.changed)
    #expect(git.value(["remote", "get-url", "origin"]) == "https://knot.example/did:plc:repo/")
    #expect(git.value(["config", "--local", "--get", "tng.gitAccount"]) == "did:plc:alice")
    #expect(
      git.values([
        "config", "--local", "--get-all",
        "credential.https://knot.example/did%3Aplc%3Arepo/.helper",
      ]) == ["", "!tng --account did:plc:alice auth git-credential"])
    #expect(
      git.value([
        "config", "--local", "--get", "credential.https://knot.example.useHttpPath",
      ]) == "true")

    #expect(
      git.run([
        "config", "--local", "--replace-all",
        "credential.https://knot.example/did%3Aplc%3Arepo/.helper", "other-helper",
      ]).status == 0)
    await #expect(throws: CLICommandError.self) {
      try await service.setup(
        remote: "origin", dryRun: false, replaceExistingHelper: false, explicitAccount: nil)
    }
  }

  @Test func existingPinnedDIDWinsOverLaterActiveAccountWithoutExplicitOverride() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = DirectoryGit(directory: directory)
    #expect(git.run(["init"]).status == 0)
    #expect(
      git.run(["remote", "add", "origin", "git@knot.example:did:plc:repo"]).status == 0)
    _ = try await makeService(git: git.recording).setup(
      remote: "origin", dryRun: false, replaceExistingHelper: false, explicitAccount: nil)

    let service = AuthGitCommandService(
      dependencies: AuthGitCommandDependencies(
        git: GitCommandRunner(run: git.recording.run),
        target: { _ in
          GitAuthenticationTarget(
            repositoryURI: "at://did:plc:alice/sh.tangled.repo/repo",
            repositoryDID: "did:plc:repo",
            knot: "knot.example",
            url: "https://knot.example/did:plc:repo/"
          )
        },
        account: { identifier in
          #expect(identifier == "did:plc:alice")
          return (
            AccountSession(did: "did:plc:alice", handle: "alice.test", isActive: false),
            InMemorySessionStore()
          )
        },
        verifyPushScope: { _, _ in }
      )
    )
    let result = try await service.setup(
      remote: "origin", dryRun: true, replaceExistingHelper: false, explicitAccount: nil)

    #expect(result.accountDID == "did:plc:alice")
    #expect(!result.changed)
  }

  @Test func restoresRemoteAndAllManagedConfigurationAfterPartialFailure() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = DirectoryGit(directory: directory)
    #expect(git.run(["init"]).status == 0)
    #expect(
      git.run(["remote", "add", "origin", "git@knot.example:did:plc:repo"]).status == 0)
    #expect(git.run(["config", "--local", "tng.gitRemote", "previous"]).status == 0)
    #expect(git.run(["config", "--local", "tng.gitURL", "https://old.example/repo/"]).status == 0)
    let failing = FailOnceGit(
      underlying: git,
      arguments: ["config", "--local", "tng.gitRemote", "origin"]
    )

    await #expect(throws: CLICommandError.self) {
      try await makeService(git: failing.recording).setup(
        remote: "origin", dryRun: false, replaceExistingHelper: false, explicitAccount: nil)
    }

    #expect(git.value(["remote", "get-url", "origin"]) == "git@knot.example:did:plc:repo")
    #expect(git.value(["config", "--local", "--get", "tng.gitRemote"]) == "previous")
    #expect(
      git.value(["config", "--local", "--get", "tng.gitURL"]) == "https://old.example/repo/")
    #expect(git.run(["config", "--local", "--get", "tng.gitAccount"]).status == 1)
    #expect(
      git.run([
        "config", "--local", "--get-all",
        "credential.https://knot.example/did%3Aplc%3Arepo/.helper",
      ]).status == 1)
  }

  @Test func liveRunnerReadsGitOutputLargerThanThePipeBuffer() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = DirectoryGit(directory: directory)
    #expect(git.run(["init"]).status == 0)
    let blob = directory.appendingPathComponent("blob")
    try String(repeating: "a", count: 1024 * 1024).write(to: blob, atomically: true, encoding: .utf8)
    let revision = git.value(["hash-object", "-w", blob.path])

    let result = try await GitCommandRunner.live.run(["-C", directory.path, "cat-file", "-p", revision])

    #expect(result.status == 0)
    #expect(result.stdout.utf8.count == 1024 * 1024)
  }

  private func makeService(git: RecordingGit) -> AuthGitCommandService {
    AuthGitCommandService(
      dependencies: AuthGitCommandDependencies(
        git: GitCommandRunner(run: git.run),
        target: { _ in
          GitAuthenticationTarget(
            repositoryURI: "at://did:plc:alice/sh.tangled.repo/repo",
            repositoryDID: "did:plc:repo",
            knot: "knot.example",
            url: "https://knot.example/did:plc:repo/"
          )
        },
        account: { _ in
          (
            AccountSession(did: "did:plc:alice", handle: "alice.test", isActive: true),
            InMemorySessionStore()
          )
        },
        verifyPushScope: { _, _ in }
      )
    )
  }
}

private final class FailOnceGit: @unchecked Sendable {
  private let lock = NSLock()
  private let underlying: DirectoryGit
  private let arguments: [String]
  private var hasFailed = false

  init(underlying: DirectoryGit, arguments: [String]) {
    self.underlying = underlying
    self.arguments = arguments
  }

  var recording: RecordingGit { RecordingGit(response: run) }

  func run(_ arguments: [String]) -> GitProcessResult {
    lock.lock()
    let shouldFail = arguments == self.arguments && !hasFailed
    if shouldFail { hasFailed = true }
    lock.unlock()
    if shouldFail {
      return GitProcessResult(status: 1, stdout: "", stderr: "injected failure")
    }
    return underlying.run(arguments)
  }
}

private struct DirectoryGit: Sendable {
  let directory: URL

  var recording: RecordingGit { RecordingGit(response: run) }

  func run(_ arguments: [String]) -> GitProcessResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory.path] + arguments
    process.standardOutput = stdout
    process.standardError = stderr
    do { try process.run() } catch {
      return GitProcessResult(status: 127, stdout: "", stderr: error.localizedDescription)
    }
    process.waitUntilExit()
    return GitProcessResult(
      status: process.terminationStatus,
      stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
  }

  func value(_ arguments: [String]) -> String {
    run(arguments).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func values(_ arguments: [String]) -> [String] {
    let output = run(arguments).stdout
    return output.split(separator: "\n", omittingEmptySubsequences: false)
      .dropLast(output.hasSuffix("\n") ? 1 : 0).map(String.init)
  }
}

private final class RecordingGit: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[String]] = []
  private let response: @Sendable ([String]) -> GitProcessResult

  init(response: @escaping @Sendable ([String]) -> GitProcessResult) {
    self.response = response
  }

  func run(_ arguments: [String]) -> GitProcessResult {
    lock.lock()
    recorded.append(arguments)
    lock.unlock()
    return response(arguments)
  }

  func commands() -> [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}
