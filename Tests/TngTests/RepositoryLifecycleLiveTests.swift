import Foundation
import SwiftTangled
import Testing

@testable import tng

@Suite struct RepositoryLifecycleLiveTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "SWIFT_TANGLED_LIVE_REPOSITORY_LIFECYCLE"
      ] == "1"
    )
  )
  func createCloneAndDeleteRepository() throws {
    guard
      let knot = ProcessInfo.processInfo.environment[
        "SWIFT_TANGLED_LIVE_REPOSITORY_KNOT"
      ], !knot.isEmpty
    else {
      throw RepositoryLifecycleLiveTestError.missingKnot
    }

    let name = "tng-live-\(UUID().uuidString.lowercased())"
    var createdTarget: RepositoryLifecycleTarget?
    defer {
      if let createdTarget {
        _ = try? TngProcess.run([
          "repo", "delete", createdTarget.recordURI, "--yes", "--json",
        ])
      }
    }

    let creation = try TngProcess.run([
      "repo", "create", name, "--knot", knot, "--default-branch", "main", "--json",
    ])
    guard creation.status == 0 else {
      throw RepositoryLifecycleLiveTestError.commandFailed(
        "create: \(creation.stderr)\(creation.stdout)"
      )
    }
    let created = try JSONDecoder().decode(
      RepositoryJSONEnvelope<RepositoryCreationResult>.self,
      from: Data(creation.stdout.utf8)
    ).result
    guard created.outcome == .created, let cloneURL = created.target.cloneURL else {
      throw RepositoryLifecycleLiveTestError.invalidCreationResult
    }
    createdTarget = created.target

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("swift-tangled-repository-live")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clone = try runGit(["clone", cloneURL, directory.appendingPathComponent(name).path])
    guard clone.status == 0 else {
      throw RepositoryLifecycleLiveTestError.commandFailed("clone: \(clone.stderr)")
    }
    let checkout = directory.appendingPathComponent(name)
    try Data("main\n".utf8).write(to: checkout.appendingPathComponent("README.md"))
    for arguments in [
      ["config", "user.name", "swift-tangled live test"],
      ["config", "user.email", "swift-tangled-live@example.invalid"],
      ["add", "README.md"],
      ["commit", "-m", "Initialize repository"],
      ["push", "origin", "main"],
      ["switch", "-c", "release"],
    ] {
      let result = try runGit(arguments, currentDirectory: checkout)
      guard result.status == 0 else {
        throw RepositoryLifecycleLiveTestError.commandFailed(
          "git \(arguments.joined(separator: " ")): \(result.stderr)"
        )
      }
    }
    try Data("release\n".utf8).write(to: checkout.appendingPathComponent("README.md"))
    for arguments in [
      ["add", "README.md"],
      ["commit", "-m", "Add release branch"],
      ["push", "origin", "release"],
    ] {
      let result = try runGit(arguments, currentDirectory: checkout)
      guard result.status == 0 else {
        throw RepositoryLifecycleLiveTestError.commandFailed(
          "git \(arguments.joined(separator: " ")): \(result.stderr)"
        )
      }
    }

    let changed = try TngProcess.run([
      "repo", "branch", "set-default", "release", created.target.recordURI, "--json",
    ])
    guard changed.status == 0 else {
      throw RepositoryLifecycleLiveTestError.commandFailed(
        "set-default: \(changed.stderr)\(changed.stdout)"
      )
    }
    let change = try JSONDecoder().decode(
      RepositoryJSONEnvelope<RepositoryDefaultBranchChangeResult>.self,
      from: Data(changed.stdout.utf8)
    ).result
    guard change.outcome == .changed, change.newBranch == "release" else {
      throw RepositoryLifecycleLiveTestError.invalidDefaultBranchResult
    }

    let view = try TngProcess.run(["repo", "view", created.target.recordURI, "--json"])
    guard view.status == 0 else {
      throw RepositoryLifecycleLiveTestError.commandFailed(
        "view: \(view.stderr)\(view.stdout)"
      )
    }
    let repositoryView = try JSONDecoder().decode(
      RepositoryView.self,
      from: Data(view.stdout.utf8)
    )
    guard repositoryView.defaultBranch?.name == "release" else {
      throw RepositoryLifecycleLiveTestError.invalidDefaultBranchResult
    }

    let remoteHead = try runGit(["ls-remote", "--symref", cloneURL, "HEAD"])
    guard remoteHead.status == 0, remoteHead.stdout.contains("ref: refs/heads/release\tHEAD") else {
      throw RepositoryLifecycleLiveTestError.invalidDefaultBranchResult
    }

    let deletion = try TngProcess.run([
      "repo", "delete", created.target.recordURI, "--yes", "--json",
    ])
    guard deletion.status == 0 else {
      throw RepositoryLifecycleLiveTestError.commandFailed(
        "delete: \(deletion.stderr)\(deletion.stdout)"
      )
    }
    let deleted = try JSONDecoder().decode(
      RepositoryJSONEnvelope<RepositoryDeletionResult>.self,
      from: Data(deletion.stdout.utf8)
    ).result
    guard deleted.outcome == .deleted else {
      throw RepositoryLifecycleLiveTestError.invalidDeletionResult
    }
    createdTarget = nil
  }

  private func runGit(
    _ arguments: [String],
    currentDirectory: URL? = nil
  ) throws -> TngProcessResult {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = currentDirectory
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    return TngProcessResult(
      status: process.terminationStatus,
      stdout: String(
        decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
      ),
      stderr: String(
        decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
      )
    )
  }
}

private enum RepositoryLifecycleLiveTestError: Error {
  case missingKnot
  case commandFailed(String)
  case invalidCreationResult
  case invalidDefaultBranchResult
  case invalidDeletionResult
}
