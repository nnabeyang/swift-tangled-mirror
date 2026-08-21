import ArgumentParser
import Foundation
import SwiftTangled

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct ArtifactCommandDependencies: Sendable {
  let list:
    @Sendable (String, String?, Int?, ArtifactSortOrder) async throws
      -> ArtifactPageRead
  let view: @Sendable (String, String) async throws -> ArtifactTagView
  let upload:
    @Sendable (String, String, URL, String?, String, Bool) async throws
      -> TangledRecord<Artifact>
  let download:
    @Sendable (String, String, String, URL, Bool) async throws
      -> ArtifactDownloadResult
  let delete:
    @Sendable (String, String, String) async throws
      -> TangledRecord<Artifact>
  let coverage: @Sendable () async throws -> BobbinCoverage
  let originURL: @Sendable () async throws -> String
  let inputIsTerminal: @Sendable () -> Bool
  let confirm: @Sendable (String) -> Bool

  static let live: ArtifactCommandDependencies = {
    let client = BobbinClient()
    let service = ArtifactService(bobbinClient: client)
    return ArtifactCommandDependencies(
      list: {
        try await service.listWithDiagnostics(
          repository: $0,
          cursor: $1,
          limit: $2,
          sort: $3,
          pdsClient: await restoredPDSClientIfAvailable()
        )
      },
      view: {
        try await service.view(
          repository: $0,
          tag: $1,
          pdsClient: await restoredPDSClientIfAvailable()
        )
      },
      upload: { repository, tag, file, name, contentType, force in
        let pdsClient = try await CLIAuthenticatedClient.make()
        return try await service.upload(
          repository: repository,
          tag: tag,
          fileURL: file,
          name: name,
          contentType: contentType,
          force: force,
          pdsClient: pdsClient
        )
      },
      download: { repository, tag, name, destination, force in
        try await service.download(
          repository: repository,
          tag: tag,
          name: name,
          destinationURL: destination,
          force: force,
          pdsClient: await restoredPDSClientIfAvailable()
        )
      },
      delete: { repository, tag, name in
        let pdsClient = try await CLIAuthenticatedClient.make()
        return try await service.delete(
          repository: repository,
          tag: tag,
          name: name,
          pdsClient: pdsClient
        )
      },
      coverage: { try await client.coverage() },
      originURL: { try await GitOriginReader().read() },
      inputIsTerminal: { standardInputIsTerminal() },
      confirm: { promptForArtifactDeletion($0) }
    )
  }()
}

struct ArtifactJSONEnvelope<Result: Codable & Sendable>: Codable, Sendable {
  let schemaVersion: Int
  let result: Result

  init(result: Result) {
    schemaVersion = 1
    self.result = result
  }
}

struct ArtifactCommandService: Sendable {
  private let dependencies: ArtifactCommandDependencies
  private let formatter: CLIFormatter

  init(
    dependencies: ArtifactCommandDependencies = .live,
    formatter: CLIFormatter = .plain
  ) {
    self.dependencies = dependencies
    self.formatter = formatter
  }

  func list(
    repository: String?,
    limit: Int,
    cursor: String?,
    sort: ArtifactSortOrder,
    json: Bool
  ) async throws -> CLICommandOutput {
    let reference = if let repository { repository } else { try await dependencies.originURL() }
    async let coverage = readBobbinCoverage(using: dependencies.coverage)
    let read = try await dependencies.list(reference, cursor, limit, sort)
    let page = read.page
    return CLICommandOutput(
      stdout: try json
        ? formatter.json(ArtifactJSONEnvelope(result: page))
        : format(page.items),
      stderr:
        formatter.cursorDiagnostic(page.cursor, json: json)
        + BobbinReadDiagnostics(
          coverage: try await coverage,
          initialPageIsEmpty: cursor == nil && page.items.isEmpty,
          authoritativeChanges: read.authoritativeChanges
        ).stderr
    )
  }

  func view(
    repository: String?,
    tag: String,
    json: Bool
  ) async throws -> CLICommandOutput {
    let reference = if let repository { repository } else { try await dependencies.originURL() }
    async let coverage = readBobbinCoverage(using: dependencies.coverage)
    let result = try await dependencies.view(reference, tag)
    return CLICommandOutput(
      stdout: try json
        ? formatter.json(ArtifactJSONEnvelope(result: result))
        : format(result),
      stderr: BobbinReadDiagnostics(
        coverage: try await coverage,
        initialPageIsEmpty: result.artifacts.isEmpty
      ).stderr
    )
  }

  func upload(
    repository: String?,
    tag: String,
    file: String,
    name: String?,
    contentType: String,
    force: Bool,
    json: Bool
  ) async throws -> CLICommandOutput {
    let reference = if let repository { repository } else { try await dependencies.originURL() }
    let fileURL = URL(fileURLWithPath: file).standardizedFileURL
    let record = try await dependencies.upload(
      reference,
      tag,
      fileURL,
      name,
      contentType,
      force
    )
    return CLICommandOutput(
      stdout: try json
        ? formatter.json(ArtifactJSONEnvelope(result: record))
        : formatUpload(record, tag: tag)
    )
  }

  func download(
    repository: String?,
    tag: String,
    name: String,
    output: String?,
    force: Bool,
    json: Bool
  ) async throws -> CLICommandOutput {
    let reference = if let repository { repository } else { try await dependencies.originURL() }
    let destination = URL(fileURLWithPath: output ?? name).standardizedFileURL
    let result = try await dependencies.download(
      reference,
      tag,
      name,
      destination,
      force
    )
    return CLICommandOutput(
      stdout: try json
        ? formatter.json(ArtifactJSONEnvelope(result: result))
        : formatter.details([
          ("Name", result.record.value.name),
          ("Saved", result.destinationURL.path),
          ("Bytes", String(result.byteCount)),
          ("Verified CID", result.verifiedCID),
          ("URI", result.record.uri),
        ])
    )
  }

  func delete(
    repository: String?,
    tag: String,
    name: String,
    confirmed: Bool,
    json: Bool
  ) async throws -> CLICommandOutput {
    let reference = if let repository { repository } else { try await dependencies.originURL() }
    if !confirmed {
      guard dependencies.inputIsTerminal() else {
        throw ValidationError("--yes is required when standard input is not a terminal")
      }
      guard dependencies.confirm("Delete artifact \(tag)/\(name)? [y/N] ") else {
        return CLICommandOutput(stdout: "Deletion cancelled.\n")
      }
    }
    let record = try await dependencies.delete(reference, tag, name)
    return CLICommandOutput(
      stdout: try json
        ? formatter.json(ArtifactJSONEnvelope(result: record))
        : formatter.details([
          ("Deleted", record.value.name),
          ("Tag hash", record.value.tagObjectHash),
          ("URI", record.uri),
        ])
    )
  }
}

extension ArtifactCommandService {
  fileprivate func format(_ records: [TangledRecord<Artifact>]) -> String {
    formatter.table(
      headers: ["NAME", "SIZE", "MEDIA TYPE", "TAG HASH", "CREATED", "URI"],
      rows: records.map {
        [
          $0.value.name,
          String($0.value.blob.size),
          $0.value.blob.mimeType,
          $0.value.tagObjectHash.prefix(12).description,
          $0.value.createdAt.rawValue,
          $0.uri,
        ]
      }
    )
  }

  fileprivate func format(_ view: ArtifactTagView) -> String {
    formatter.details([
      ("Tag", view.tag.reference.name),
      ("Tag hash", view.tag.reference.hash),
      ("Target", view.tag.targetHash),
      ("Tagger", view.tag.tagger?.name),
      ("Created", view.tag.tagger?.when.rawValue),
      ("Message", view.tag.message),
    ]) + format(view.artifacts)
  }

  fileprivate func formatUpload(
    _ record: TangledRecord<Artifact>,
    tag: String
  ) -> String {
    formatter.details([
      ("Uploaded", record.value.name),
      ("Tag", tag),
      ("Tag hash", record.value.tagObjectHash),
      ("Bytes", String(record.value.blob.size)),
      ("Media type", record.value.blob.mimeType),
      ("CID", record.value.blob.cid),
      ("URI", record.uri),
    ])
  }
}

private func standardInputIsTerminal() -> Bool {
  #if canImport(Darwin)
    Darwin.isatty(FileHandle.standardInput.fileDescriptor) == 1
  #elseif canImport(Glibc)
    Glibc.isatty(FileHandle.standardInput.fileDescriptor) == 1
  #else
    false
  #endif
}

private func promptForArtifactDeletion(_ prompt: String) -> Bool {
  FileHandle.standardError.write(Data(prompt.utf8))
  guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
    return false
  }
  return response.lowercased() == "y" || response.lowercased() == "yes"
}

private func restoredPDSClientIfAvailable() async -> PDSClient? {
  do {
    return try await CLIAuthenticatedClient.make()
  } catch {
    return nil
  }
}
