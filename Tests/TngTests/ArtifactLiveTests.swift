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
        _ = try? TngProcess.run([
          "artifact", "delete", tag, name, "--repo", repository, "--yes", "--json",
        ])
      }
    }

    let upload = try TngProcess.run([
      "artifact", "upload", tag, source.path, "--repo", repository, "--name", name,
      "--content-type", "text/plain", "--json",
    ])
    try requireSuccess(upload, operation: "upload")
    recordCreated = true
    #expect(upload.stdout.contains("\"schemaVersion\" : 1"))

    try await waitUntil {
      let view = try TngProcess.run([
        "artifact", "view", tag, "--repo", repository, "--json",
      ])
      return view.status == 0 && view.stdout.contains(name)
    }

    let download = try TngProcess.run([
      "artifact", "download", tag, name, "--repo", repository,
      "--output", destination.path, "--json",
    ])
    try requireSuccess(download, operation: "download")
    #expect(try Data(contentsOf: destination) == Data("artifact-live-one\n".utf8))

    try Data("artifact-live-two\n".utf8).write(to: source)
    let overwrite = try TngProcess.run([
      "artifact", "upload", tag, source.path, "--repo", repository, "--name", name,
      "--content-type", "text/plain", "--force", "--json",
    ])
    try requireSuccess(overwrite, operation: "force upload")

    try await waitUntil {
      let refreshed = try TngProcess.run([
        "artifact", "download", tag, name, "--repo", repository,
        "--output", destination.path, "--force", "--json",
      ])
      return refreshed.status == 0
        && (try? Data(contentsOf: destination)) == Data("artifact-live-two\n".utf8)
    }

    let deletion = try TngProcess.run([
      "artifact", "delete", tag, name, "--repo", repository, "--yes", "--json",
    ])
    try requireSuccess(deletion, operation: "delete")
    recordCreated = false

    try await waitUntil {
      let view = try TngProcess.run([
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
    _ result: TngProcessResult,
    operation: String
  ) throws {
    guard result.status == 0 else {
      throw ArtifactLiveTestError.commandFailed(
        "\(operation): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
  }
}

private enum ArtifactLiveTestError: Error {
  case missingConfiguration
  case commandFailed(String)
  case timedOut
}
