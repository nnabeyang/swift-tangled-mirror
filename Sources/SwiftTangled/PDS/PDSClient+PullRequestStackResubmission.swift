import Foundation
import SwiftAtproto
import TangledLexicons

extension PDSClient {
  package func applyPullRequestStackResubmission(
    _ prepared: PreparedPullRequestStackResubmission
  ) async throws -> PullRequestStackResubmissionResult {
    try requirePullScope()
    let ownerDID = try ownerDID(of: prepared.context.selectedURI)
    guard ownerDID == repoDID else {
      throw TangledError.invalidRequest("only the Pull Request owner can resubmit it")
    }

    let writable = prepared.plan.operations.filter {
      $0.kind == .create || $0.kind == .update
    }
    var blobs: [String: LexBlob] = [:]
    for operation in writable {
      guard let commit = prepared.commitsByURI[operation.pullRequestURI] else {
        throw TangledError.invalidRequest("stack resubmission operation is missing its patch")
      }
      let compressed = try GzipCompressor.compress(commit.patch)
      let upload = try await perform {
        try await client.RepoUploadBlob(
          input: XRPCBlobUpload(data: compressed, mimeType: "application/gzip")
        )
      }
      blobs[operation.pullRequestURI] = upload.blob
    }

    let createdAt = FormatString(now())
    let selected = prepared.context.snapshots[prepared.context.selectedURI]!.record.value
    var writes: [Com.Atproto.RepoApplyWrites_Input_Writes_Elem] = []
    var rawValues: [String: UnknownATPValue] = [:]
    var writeOperations: [PullRequestStackResubmissionOperation] = []
    for operation in prepared.plan.operations {
      let uri = try ATURI(string: operation.pullRequestURI)
      guard let rkey = uri.rkey else {
        throw TangledError.invalidRequest("pull request URI must include an rkey")
      }
      switch operation.kind {
      case .create:
        let commit = prepared.commitsByURI[operation.pullRequestURI]!
        let blob = blobs[operation.pullRequestURI]!
        let record = Sh.Tangled.RepoPull(
          body: normalizedBody(commit.body),
          createdAt: createdAt,
          dependentOn: operation.dependentOn.map(FormatString.init(rawValue:)),
          mentions: [],
          references: [],
          rounds: [.init(createdAt: createdAt, patchBlob: blob)],
          source: selected.source.map {
            .init(
              branch: $0.branch,
              repo: $0.repositoryDID.map(FormatString.init(rawValue:))
            )
          },
          target: .init(
            branch: selected.target.branch,
            repo: FormatString(rawValue: selected.target.repositoryDID)
          ),
          title: commit.title
        )
        let raw = UnknownATPValue.record(record)
        rawValues[operation.pullRequestURI] = raw
        writes.append(
          .repoApplyWritesCreate(
            .init(
              collection: FormatString(rawValue: Self.pullCollection),
              rkey: FormatString(rkey),
              value: raw
            )
          )
        )
        writeOperations.append(operation)
      case .update:
        let snapshot = prepared.context.snapshots[operation.pullRequestURI]!
        let commit = prepared.commitsByURI[operation.pullRequestURI]!
        let raw = try replacingStackFields(
          in: snapshot.rawValue,
          commit: commit,
          dependentOn: operation.dependentOn,
          createdAt: createdAt,
          blob: blobs[operation.pullRequestURI]!
        )
        rawValues[operation.pullRequestURI] = raw
        writes.append(
          .repoApplyWritesUpdate(
            .init(
              collection: FormatString(rawValue: Self.pullCollection),
              rkey: FormatString(rkey),
              value: raw
            )
          )
        )
        writeOperations.append(operation)
      case .delete:
        writes.append(
          .repoApplyWritesDelete(
            .init(
              collection: FormatString(rawValue: Self.pullCollection),
              rkey: FormatString(rkey)
            )
          )
        )
        writeOperations.append(operation)
      case .preserveMerged:
        break
      }
    }
    guard !writes.isEmpty else {
      throw TangledError.invalidRequest("stack resubmission does not contain any writable changes")
    }

    let output: Com.Atproto.RepoApplyWrites_Output
    do {
      output = try await perform {
        try await client.RepoApplyWrites(
          input: .init(
            repo: FormatString(rawValue: repoDID),
            swapCommit: FormatString(rawValue: prepared.context.expectedRepoCommit),
            validate: nil,
            writes: writes
          )
        )
      }
    } catch let error as TangledError {
      throw error
    } catch {
      let uploaded = blobs.values.map { $0.ref.toBaseEncodedString }.sorted().joined(separator: ", ")
      throw TangledError.transport(
        "\(error) (uploaded patch blobs: \(uploaded))"
      )
    }
    guard let results = output.results, results.count == writeOperations.count else {
      throw TangledError.decoding(PDSClientError.invalidApplyWritesResult)
    }

    var records: [String: TangledRecord<PullRequest>] = [:]
    var deleted: [String] = []
    for (operation, result) in zip(writeOperations, results) {
      switch (operation.kind, result) {
      case (.create, .repoApplyWritesCreateResult(let value)):
        guard value.uri.rawValue == operation.pullRequestURI,
          let raw = rawValues[operation.pullRequestURI]
        else {
          throw TangledError.decoding(PDSClientError.invalidApplyWritesResult)
        }
        records[operation.pullRequestURI] = try TangledRecordDecoder.pullRequest(
          uri: value.uri.rawValue,
          cid: value.cid.rawValue,
          value: raw
        )
      case (.update, .repoApplyWritesUpdateResult(let value)):
        guard value.uri.rawValue == operation.pullRequestURI,
          let raw = rawValues[operation.pullRequestURI]
        else {
          throw TangledError.decoding(PDSClientError.invalidApplyWritesResult)
        }
        records[operation.pullRequestURI] = try TangledRecordDecoder.pullRequest(
          uri: value.uri.rawValue,
          cid: value.cid.rawValue,
          value: raw
        )
      case (.delete, .repoApplyWritesDeleteResult):
        deleted.append(operation.pullRequestURI)
      default:
        throw TangledError.decoding(PDSClientError.invalidApplyWritesResult)
      }
    }
    for operation in prepared.plan.operations where operation.kind == .preserveMerged {
      records[operation.pullRequestURI] =
        prepared.context.snapshots[operation.pullRequestURI]?.record
    }
    let orderedRecords: [TangledRecord<PullRequest>] = prepared.plan.operations.compactMap {
      guard $0.kind != .delete else { return nil }
      return records[$0.pullRequestURI]
    }
    return PullRequestStackResubmissionResult(
      plan: prepared.plan,
      pullRequests: orderedRecords,
      deletedPullRequestURIs: deleted
    )
  }

  private func ownerDID(of rawURI: String) throws -> String {
    let uri = try ATURI(string: rawURI)
    guard case .did(let did) = uri.authority else {
      throw TangledError.invalidRequest("pull request URI owner must be a DID")
    }
    return did.rawValue
  }

  private func replacingStackFields(
    in raw: UnknownATPValue,
    commit: PullRequestStackCommit,
    dependentOn: String?,
    createdAt: FormatString<Date>,
    blob: LexBlob
  ) throws -> UnknownATPValue {
    let encoded = try JSONEncoder().encode(raw)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
      var rounds = object["rounds"] as? [[String: Any]]
    else {
      throw TangledError.decoding(PDSClientError.invalidPullRequestRecord)
    }
    object["title"] = commit.title
    if let body = normalizedBody(commit.body) {
      object["body"] = body
    } else {
      object.removeValue(forKey: "body")
    }
    if let dependentOn {
      object["dependentOn"] = dependentOn
    } else {
      object.removeValue(forKey: "dependentOn")
    }
    let blobObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(blob))
    rounds.append(["createdAt": createdAt.rawValue, "patchBlob": blobObject])
    object["rounds"] = rounds
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.userInfo[.atprotoLexiconDecodingMode] = LexiconDecodingMode.permissive
    return try decoder.decode(UnknownATPValue.self, from: data)
  }

  private func normalizedBody(_ body: String?) -> String? {
    guard let value = body?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }
}
