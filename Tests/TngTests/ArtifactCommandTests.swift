import ArgumentParser
import Foundation
import SwiftAtproto
import SwiftTangled
import Testing

@testable import tng

@Suite struct ArtifactCommandTests {
  @Test func parsesArtifactCommandsAndOptions() throws {
    let list = try ArtifactListCommand.parse([
      "alice.example/core", "--limit", "25", "--cursor", "next", "--sort", "asc",
      "--json",
    ])
    #expect(list.repository == "alice.example/core")
    #expect(list.limit == 25)
    #expect(list.cursor == "next")
    #expect(list.sort == "asc")
    #expect(list.json)

    let view = try ArtifactViewCommand.parse(["v1.0.0", "--repo", "alice/core", "--json"])
    #expect(view.tag == "v1.0.0")
    #expect(view.repo == "alice/core")
    #expect(view.json)

    let upload = try ArtifactUploadCommand.parse([
      "v1.0.0", "build.tar.gz", "--repo", "alice/core", "--name", "release.tar.gz",
      "--content-type", "application/gzip", "--force", "--json",
    ])
    #expect(upload.file == "build.tar.gz")
    #expect(upload.name == "release.tar.gz")
    #expect(upload.contentType == "application/gzip")
    #expect(upload.force)

    let download = try ArtifactDownloadCommand.parse([
      "v1.0.0", "release.tar.gz", "-o", "downloads/release.tar.gz", "--force", "--json",
    ])
    #expect(download.output == "downloads/release.tar.gz")
    #expect(download.force)

    let delete = try ArtifactDeleteCommand.parse([
      "v1.0.0", "release.tar.gz", "--yes", "--json",
    ])
    #expect(delete.yes)
    #expect(delete.json)
  }

  @Test func listValidationRejectsInvalidLimitAndSort() {
    #expect(throws: (any Error).self) {
      _ = try ArtifactListCommand.parse(["--limit", "0"])
    }
    #expect(throws: (any Error).self) {
      _ = try ArtifactListCommand.parse(["--sort", "newest"])
    }
  }

  @Test func listUsesOriginAndProducesVersionedJSON() async throws {
    let recorder = ArtifactDependencyRecorder()
    let service = ArtifactCommandService(
      dependencies: dependencies(recorder: recorder),
      formatter: .plain
    )

    let output = try await service.list(
      repository: nil,
      limit: 25,
      cursor: "next",
      sort: .asc,
      json: true
    )
    let envelope = try JSONDecoder().decode(
      ArtifactJSONEnvelope<Page<TangledRecord<Artifact>>>.self,
      from: Data(output.stdout.utf8)
    )

    #expect(envelope.schemaVersion == 1)
    #expect(envelope.result.items == [artifactRecord()])
    #expect(envelope.result.cursor == "following")
    #expect(output.stderr.isEmpty)
    #expect(
      await recorder.listCalls()
        == [
          ArtifactListCall(
            repository: "git@tangled.org:alice.example/core",
            cursor: "next",
            limit: 25,
            sort: .asc
          )
        ]
    )
  }

  @Test func listReportsAuthoritativeArtifactChangesOnStderr() async throws {
    let service = ArtifactCommandService(
      dependencies: dependencies(authoritativeChanges: 2),
      formatter: .plain
    )

    let output = try await service.list(
      repository: "alice.example/core",
      limit: 30,
      cursor: nil,
      sort: .desc,
      json: true
    )

    #expect(output.stdout.contains("\"schemaVersion\" : 1"))
    #expect(output.stderr.contains("Merged 2 authoritative PDS records"))
  }

  @Test func humanViewIncludesTagAndArtifactDetails() async throws {
    let service = ArtifactCommandService(
      dependencies: dependencies(),
      formatter: .plain
    )
    let output = try await service.view(
      repository: "alice/core",
      tag: "v1.0.0",
      json: false
    )

    #expect(output.stdout.contains("Tag\tv1.0.0"))
    #expect(output.stdout.contains("Artifact release"))
    #expect(output.stdout.contains("release.tar.gz"))
    #expect(output.stdout.contains("application/gzip"))
  }

  @Test func uploadForwardsFileMetadataAndWrapsJSON() async throws {
    let recorder = ArtifactDependencyRecorder()
    let service = ArtifactCommandService(
      dependencies: dependencies(recorder: recorder),
      formatter: .plain
    )
    let output = try await service.upload(
      repository: "alice/core",
      tag: "v1.0.0",
      file: "./build.tar.gz",
      name: "release.tar.gz",
      contentType: "application/gzip",
      force: true,
      json: true
    )
    let envelope = try JSONDecoder().decode(
      ArtifactJSONEnvelope<TangledRecord<Artifact>>.self,
      from: Data(output.stdout.utf8)
    )

    #expect(envelope.schemaVersion == 1)
    #expect(envelope.result == artifactRecord())
    let call = try #require(await recorder.uploadCalls().first)
    #expect(call.repository == "alice/core")
    #expect(call.tag == "v1.0.0")
    #expect(call.file.lastPathComponent == "build.tar.gz")
    #expect(call.name == "release.tar.gz")
    #expect(call.contentType == "application/gzip")
    #expect(call.force)
  }

  @Test func downloadDefaultsToArtifactNameAndReportsVerifiedCID() async throws {
    let recorder = ArtifactDependencyRecorder()
    let service = ArtifactCommandService(
      dependencies: dependencies(recorder: recorder),
      formatter: .plain
    )
    let output = try await service.download(
      repository: "alice/core",
      tag: "v1.0.0",
      name: "release.tar.gz",
      output: nil,
      force: false,
      json: false
    )

    let call = try #require(await recorder.downloadCalls().first)
    #expect(call.destination.lastPathComponent == "release.tar.gz")
    #expect(!call.force)
    #expect(output.stdout.contains("Verified CID"))
    #expect(output.stdout.contains(artifactRecord().value.blob.cid))
  }

  @Test func deleteRequiresYesOutsideTTYAndCancellationDoesNotWrite() async throws {
    let recorder = ArtifactDependencyRecorder()
    let nonInteractive = ArtifactCommandService(
      dependencies: dependencies(recorder: recorder, inputIsTerminal: false),
      formatter: .plain
    )
    await #expect(throws: ValidationError.self) {
      _ = try await nonInteractive.delete(
        repository: "alice/core",
        tag: "v1.0.0",
        name: "release.tar.gz",
        confirmed: false,
        json: false
      )
    }

    let cancelled = ArtifactCommandService(
      dependencies: dependencies(
        recorder: recorder,
        inputIsTerminal: true,
        confirmation: false
      ),
      formatter: .plain
    )
    let output = try await cancelled.delete(
      repository: "alice/core",
      tag: "v1.0.0",
      name: "release.tar.gz",
      confirmed: false,
      json: false
    )
    #expect(output.stdout == "Deletion cancelled.\n")
    #expect(await recorder.deleteCalls().isEmpty)
  }

  @Test func deleteWithYesSkipsPromptAndReturnsVersionedJSON() async throws {
    let recorder = ArtifactDependencyRecorder()
    let service = ArtifactCommandService(
      dependencies: dependencies(
        recorder: recorder,
        inputIsTerminal: false,
        confirmation: false
      ),
      formatter: .plain
    )
    let output = try await service.delete(
      repository: "alice/core",
      tag: "v1.0.0",
      name: "release.tar.gz",
      confirmed: true,
      json: true
    )
    let envelope = try JSONDecoder().decode(
      ArtifactJSONEnvelope<TangledRecord<Artifact>>.self,
      from: Data(output.stdout.utf8)
    )

    #expect(envelope.result == artifactRecord())
    #expect(await recorder.deleteCalls().count == 1)
  }

  @Test func artifactErrorsUseStableAPIReports() {
    let existing = ArtifactError.alreadyExists(
      uri: "at://did:plc:alice/sh.tangled.repo.artifact/key"
    )
    #expect(exitCode(for: existing) == CLIExitCode.api.rawValue)
    #expect(jsonErrorReport(for: existing).category == "api")
    #expect(jsonErrorReport(for: existing).code == "artifact_already_exists")
    #expect(
      errorReport(for: ArtifactError.tagNotAnnotated("snapshot")).diagnostic.contains(
        "remote tag is not annotated"
      )
    )
  }
}

private struct ArtifactListCall: Equatable, Sendable {
  let repository: String
  let cursor: String?
  let limit: Int?
  let sort: ArtifactSortOrder
}

private struct ArtifactUploadCall: Sendable {
  let repository: String
  let tag: String
  let file: URL
  let name: String?
  let contentType: String
  let force: Bool
}

private struct ArtifactDownloadCall: Sendable {
  let destination: URL
  let force: Bool
}

private actor ArtifactDependencyRecorder {
  private var recordedLists: [ArtifactListCall] = []
  private var recordedUploads: [ArtifactUploadCall] = []
  private var recordedDownloads: [ArtifactDownloadCall] = []
  private var recordedDeletes: [(String, String, String)] = []

  func recordList(_ call: ArtifactListCall) {
    recordedLists.append(call)
  }

  func recordUpload(_ call: ArtifactUploadCall) {
    recordedUploads.append(call)
  }

  func recordDownload(_ call: ArtifactDownloadCall) {
    recordedDownloads.append(call)
  }

  func recordDelete(repository: String, tag: String, name: String) {
    recordedDeletes.append((repository, tag, name))
  }

  func listCalls() -> [ArtifactListCall] { recordedLists }
  func uploadCalls() -> [ArtifactUploadCall] { recordedUploads }
  func downloadCalls() -> [ArtifactDownloadCall] { recordedDownloads }
  func deleteCalls() -> [(String, String, String)] { recordedDeletes }
}

private func dependencies(
  recorder: ArtifactDependencyRecorder = ArtifactDependencyRecorder(),
  inputIsTerminal: Bool = false,
  confirmation: Bool = true,
  authoritativeChanges: Int = 0
) -> ArtifactCommandDependencies {
  ArtifactCommandDependencies(
    list: { repository, cursor, limit, sort in
      await recorder.recordList(
        ArtifactListCall(
          repository: repository,
          cursor: cursor,
          limit: limit,
          sort: sort
        )
      )
      return ArtifactPageRead(
        page: Page(items: [artifactRecord()], cursor: "following"),
        authoritativeChanges: authoritativeChanges
      )
    },
    view: { _, _ in artifactView() },
    upload: { repository, tag, file, name, contentType, force in
      await recorder.recordUpload(
        ArtifactUploadCall(
          repository: repository,
          tag: tag,
          file: file,
          name: name,
          contentType: contentType,
          force: force
        )
      )
      return artifactRecord()
    },
    download: { _, _, _, destination, force in
      await recorder.recordDownload(
        ArtifactDownloadCall(destination: destination, force: force)
      )
      return ArtifactDownloadResult(
        record: artifactRecord(),
        destinationURL: destination,
        byteCount: 1_024,
        verifiedCID: artifactRecord().value.blob.cid
      )
    },
    delete: { repository, tag, name in
      await recorder.recordDelete(repository: repository, tag: tag, name: name)
      return artifactRecord()
    },
    coverage: {
      BobbinCoverage(ready: true, eventsProcessed: 100, lastCursor: 100)
    },
    originURL: { "git@tangled.org:alice.example/core" },
    inputIsTerminal: { inputIsTerminal },
    confirm: { _ in confirmation }
  )
}

private func artifactView() -> ArtifactTagView {
  ArtifactTagView(
    tag: GitTag(
      reference: GitReference(
        name: "v1.0.0",
        hash: String(repeating: "a", count: 40)
      ),
      tagger: GitSignature(
        name: "Artifact release",
        email: "release@example.com",
        when: FormatString(rawValue: "2026-07-25T12:00:00Z")
      ),
      message: "Artifact release",
      targetHash: String(repeating: "b", count: 40)
    ),
    artifacts: [artifactRecord()]
  )
}

private func artifactRecord() -> TangledRecord<Artifact> {
  TangledRecord(
    uri: "at://did:plc:alice/sh.tangled.repo.artifact/3artifact",
    cid: "bafyrecord",
    value: Artifact(
      repositoryDID: "did:plc:repository",
      tagObjectHash: String(repeating: "a", count: 40),
      name: "release.tar.gz",
      blob: BlobReference(
        cid: "bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a",
        mimeType: "application/gzip",
        size: 1_024
      ),
      createdAt: FormatString(rawValue: "2026-07-25T12:34:56Z")
    )
  )
}
