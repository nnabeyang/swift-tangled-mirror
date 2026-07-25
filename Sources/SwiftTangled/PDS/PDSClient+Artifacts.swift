import Foundation
import SwiftAtproto
import TangledLexicons

extension PDSClient {
  package func artifactRecords(
    repositoryDID: String
  ) async throws -> [TangledRecord<Artifact>] {
    var cursor: String?
    var seenCursors = Set<String>()
    var records: [TangledRecord<Artifact>] = []

    repeat {
      let output = try await perform {
        try await client.RepoListRecords(
          collection: FormatString(rawValue: Sh.Tangled.RepoArtifact.nsId),
          cursor: cursor,
          limit: 100,
          repo: FormatString(rawValue: repoDID),
          reverse: nil
        )
      }
      records.append(
        contentsOf: try output.records.compactMap {
          try decodeArtifactRecord($0, repositoryDID: repositoryDID)
        }
      )
      guard let next = output.cursor else { break }
      guard seenCursors.insert(next).inserted else {
        throw TangledError.transport("PDS returned a repeated pagination cursor")
      }
      cursor = next
    } while true

    return records
  }

  public func uploadArtifact(
    repositoryURI: String,
    repositoryDID: String,
    tagObjectHash: String,
    name: String,
    contentType: String = "application/octet-stream",
    data: Data,
    replacing current: TangledRecord<Artifact>? = nil
  ) async throws -> TangledRecord<Artifact> {
    let collection = Sh.Tangled.RepoArtifact.nsId
    guard let repository = FormatString<ATURI>(rawValue: repositoryURI).typed,
      repository.collection?.rawValue == "sh.tangled.repo",
      repository.rkey != nil
    else {
      throw TangledError.invalidRequest("repository URI must identify a sh.tangled.repo record")
    }
    guard let parsedRepositoryDID = FormatString<DID>(rawValue: repositoryDID).typed else {
      throw TangledError.invalidRequest("invalid repository DID: \(repositoryDID)")
    }
    let name = try ArtifactValidation.name(name)
    guard !contentType.isEmpty else {
      throw TangledError.invalidRequest("artifact content type must not be empty")
    }
    guard data.count <= Artifact.maximumSize else {
      throw ArtifactError.fileTooLarge(
        maximumBytes: Int64(Artifact.maximumSize),
        actualBytes: Int64(data.count)
      )
    }
    let tag = try ArtifactValidation.tagData(tagObjectHash)
    guard grantedScopes.allowsRepo(collection: collection, action: .update) else {
      throw TangledError.insufficientScope("repo:\(collection)")
    }
    guard grantedScopes.allowsBlob(mime: contentType) else {
      throw TangledError.insufficientScope("blob:\(contentType)")
    }

    let rkey: String
    let swapRecord: FormatString<LexLink>?
    if let current {
      let owner = try ArtifactValidation.recordOwner(current.uri, collection: collection)
      guard owner.rawValue == repoDID else {
        throw ArtifactError.notOwned(uri: current.uri)
      }
      guard current.value.repositoryDID == repositoryDID,
        current.value.tagObjectHash == tagObjectHash.lowercased(),
        current.value.name == name
      else {
        throw TangledError.invalidRequest("replacement artifact identity does not match")
      }
      guard let currentCID = current.cid,
        let uri = FormatString<ATURI>(rawValue: current.uri).typed,
        let currentRkey = uri.rkey?.rawValue
      else {
        throw TangledError.invalidRequest("replacement artifact does not expose a CID and rkey")
      }
      rkey = currentRkey
      swapRecord = FormatString(rawValue: currentCID)
    } else {
      rkey = nextRecordKey()
      swapRecord = nil
    }

    let upload = try await perform {
      try await client.RepoUploadBlob(
        input: XRPCBlobUpload(data: data, mimeType: contentType)
      )
    }
    let createdAt = FormatString(now())
    let record = Sh.Tangled.RepoArtifact(
      artifact: upload.blob,
      createdAt: createdAt,
      name: name,
      repo: FormatString(repository),
      repoDid: FormatString(parsedRepositoryDID),
      tag: tag
    )
    let output = try await perform {
      try await client.RepoPutRecord(
        input: Com.Atproto.RepoPutRecord_Input(
          collection: FormatString(rawValue: collection),
          record: .record(record),
          repo: FormatString(rawValue: repoDID),
          rkey: FormatString(rawValue: rkey),
          swapRecord: swapRecord,
          validate: nil
        )
      )
    }
    return TangledRecord(
      uri: output.uri.rawValue,
      cid: output.cid.rawValue,
      value: Artifact(
        repositoryDID: repositoryDID,
        tagObjectHash: tag.hexString,
        name: name,
        blob: BlobReference(
          cid: upload.blob.ref.toBaseEncodedString,
          mimeType: upload.blob.mimeType,
          size: Int(upload.blob.size)
        ),
        createdAt: createdAt
      )
    )
  }

  public func deleteArtifact(_ current: TangledRecord<Artifact>) async throws {
    let collection = Sh.Tangled.RepoArtifact.nsId
    guard grantedScopes.allowsRepo(collection: collection, action: .delete) else {
      throw TangledError.insufficientScope("repo:\(collection)")
    }
    let owner = try ArtifactValidation.recordOwner(current.uri, collection: collection)
    guard owner.rawValue == repoDID else {
      throw ArtifactError.notOwned(uri: current.uri)
    }
    guard let currentCID = current.cid,
      let uri = FormatString<ATURI>(rawValue: current.uri).typed,
      let rkey = uri.rkey
    else {
      throw TangledError.invalidRequest("artifact does not expose a CID and rkey")
    }
    _ = try await perform {
      try await client.RepoDeleteRecord(
        input: Com.Atproto.RepoDeleteRecord_Input(
          collection: FormatString(rawValue: collection),
          repo: FormatString(rawValue: repoDID),
          rkey: FormatString(rkey),
          swapRecord: FormatString(rawValue: currentCID)
        )
      )
    }
  }

  private func decodeArtifactRecord(
    _ record: Com.Atproto.RepoListRecords_Record,
    repositoryDID: String
  ) throws -> TangledRecord<Artifact>? {
    guard case .record(let value) = record.value,
      let artifact = value as? Sh.Tangled.RepoArtifact,
      artifact.repoDid?.rawValue == repositoryDID
    else {
      return nil
    }
    return try TangledRecordDecoder.artifact(
      uri: record.uri.rawValue,
      cid: record.cid.rawValue,
      repositoryDID: repositoryDID,
      tag: artifact.tag,
      name: artifact.name,
      blob: BlobReference(
        cid: artifact.artifact.ref.toBaseEncodedString,
        mimeType: artifact.artifact.mimeType,
        size: Int(artifact.artifact.size)
      ),
      createdAt: artifact.createdAt
    )
  }
}
