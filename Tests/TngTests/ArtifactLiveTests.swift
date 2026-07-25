import Foundation
import Testing

@Suite struct ArtifactLiveTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["SWIFT_TANGLED_LIVE_ARTIFACT"] == "1"
    )
  )
  func uploadReadDownloadOverwriteAndDeleteOnTangled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let repository = environment["SWIFT_TANGLED_LIVE_ARTIFACT_REPOSITORY"],
      !repository.isEmpty,
      let tag = environment["SWIFT_TANGLED_LIVE_ARTIFACT_TAG"],
      !tag.isEmpty
    else {
      throw ArtifactLiveTestError.missingConfiguration
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("swift-tangled-artifact-live")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let name = "tng-live-\(UUID().uuidString.lowercased()).txt"
    let source = directory.appendingPathComponent("source.txt")
    let destination = directory.appendingPathComponent("download.txt")
    try Data("artifact-live-one\n".utf8).write(to: source)

    var recordCreated = false
    defer {
      if recordCreated {
        _ = try? ArtifactLiveProcess.run([
          "artifact", "delete", tag, name, "--repo", repository, "--yes", "--json",
        ])
      }
    }

    let upload = try ArtifactLiveProcess.run([
      "artifact", "upload", tag, source.path, "--repo", repository, "--name", name,
      "--content-type", "text/plain", "--json",
    ])
    try requireSuccess(upload, operation: "upload")
    recordCreated = true
    #expect(upload.stdout.contains("\"schemaVersion\" : 1"))

    try await waitUntil {
      let view = try ArtifactLiveProcess.run([
        "artifact", "view", tag, "--repo", repository, "--json",
      ])
      return view.status == 0 && view.stdout.contains(name)
    }

    let download = try ArtifactLiveProcess.run([
      "artifact", "download", tag, name, "--repo", repository,
      "--output", destination.path, "--json",
    ])
    try requireSuccess(download, operation: "download")
    #expect(try Data(contentsOf: destination) == Data("artifact-live-one\n".utf8))

    try Data("artifact-live-two\n".utf8).write(to: source)
    let overwrite = try ArtifactLiveProcess.run([
      "artifact", "upload", tag, source.path, "--repo", repository, "--name", name,
      "--content-type", "text/plain", "--force", "--json",
    ])
    try requireSuccess(overwrite, operation: "force upload")

    try await waitUntil {
      let refreshed = try ArtifactLiveProcess.run([
        "artifact", "download", tag, name, "--repo", repository,
        "--output", destination.path, "--force", "--json",
      ])
      return refreshed.status == 0
        && (try? Data(contentsOf: destination)) == Data("artifact-live-two\n".utf8)
    }

    let deletion = try ArtifactLiveProcess.run([
      "artifact", "delete", tag, name, "--repo", repository, "--yes", "--json",
    ])
    try requireSuccess(deletion, operation: "delete")
    recordCreated = false

    try await waitUntil {
      let view = try ArtifactLiveProcess.run([
        "artifact", "view", tag, "--repo", repository, "--json",
      ])
      return view.status == 0 && !view.stdout.contains(name)
    }
  }

  private func waitUntil(
    timeout: Duration = .seconds(60),
    operation: () throws -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    repeat {
      if try operation() {
        return
      }
      try await Task.sleep(for: .seconds(1))
    } while clock.now < deadline
    throw ArtifactLiveTestError.timedOut
  }

  private func requireSuccess(
    _ result: ArtifactLiveProcessResult,
    operation: String
  ) throws {
    guard result.status == 0 else {
      throw ArtifactLiveTestError.commandFailed(
        "\(operation): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
  }
}

private struct ArtifactLiveProcessResult {
  let status: Int32
  let stdout: String
  let stderr: String
}

private enum ArtifactLiveProcess {
  static func run(_ arguments: [String]) throws -> ArtifactLiveProcessResult {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = try executableURL()
    process.arguments = arguments
    process.standardOutput = standardOutput
    process.standardError = standardError
    var environment = ProcessInfo.processInfo.environment
    environment["NO_COLOR"] = "1"
    process.environment = environment

    try process.run()
    process.waitUntilExit()
    return ArtifactLiveProcessResult(
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

  private static func executableURL() throws -> URL {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let candidates = [
      packageRoot.appendingPathComponent(".build/debug/tng"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/debug/tng"),
      Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("tng"),
    ]
    guard
      let executable = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
      })
    else {
      throw ArtifactLiveTestError.executableNotFound
    }
    return executable
  }
}

private enum ArtifactLiveTestError: Error {
  case missingConfiguration
  case executableNotFound
  case commandFailed(String)
  case timedOut
}
