import Foundation
import SwiftAtproto
import TangledLexicons

enum TangledRecordDecoder {
  static func repository(
    uri: String,
    cid: String?,
    value: UnknownATPValue
  ) throws(TangledError) -> TangledRecord<Repository> {
    let wire: Sh.Tangled.Repo = try decode(value)
    return TangledRecord(
      uri: uri,
      cid: cid,
      value: Repository(
        name: wire.name,
        knot: wire.knot,
        spindle: wire.spindle,
        description: wire.description,
        website: wire.website?.rawValue,
        topics: wire.topics ?? [],
        source: wire.source?.rawValue,
        labels: wire.labels?.map(\.rawValue) ?? [],
        repoDID: wire.repoDid?.rawValue,
        createdAt: wire.createdAt
      )
    )
  }

  static func issue(
    uri: String,
    cid: String?,
    value: UnknownATPValue
  ) throws(TangledError) -> TangledRecord<Issue> {
    let wire: Sh.Tangled.RepoIssue = try decode(value)
    return TangledRecord(
      uri: uri,
      cid: cid,
      value: Issue(
        repositoryDID: wire.repo.rawValue,
        title: wire.title,
        body: wire.body,
        createdAt: wire.createdAt,
        mentions: wire.mentions?.map(\.rawValue) ?? [],
        references: wire.references?.map(\.rawValue) ?? []
      )
    )
  }

  static func pullRequest(
    uri: String,
    cid: String?,
    value: UnknownATPValue
  ) throws(TangledError) -> TangledRecord<PullRequest> {
    let wire: Sh.Tangled.RepoPull = try decode(value)
    return TangledRecord(
      uri: uri,
      cid: cid,
      value: PullRequest(
        title: wire.title,
        body: wire.body,
        rounds: wire.rounds.map {
          PullRequestRound(
            createdAt: $0.createdAt,
            patchBlob: BlobReference(
              cid: $0.patchBlob.ref.toBaseEncodedString,
              mimeType: $0.patchBlob.mimeType,
              size: Int($0.patchBlob.size)
            )
          )
        },
        source: wire.source.map {
          PullRequestSource(branch: $0.branch, repositoryDID: $0.repo?.rawValue)
        },
        target: PullRequestTarget(
          branch: wire.target.branch,
          repositoryDID: wire.target.repo.rawValue
        ),
        createdAt: wire.createdAt,
        mentions: wire.mentions?.map(\.rawValue) ?? [],
        references: wire.references?.map(\.rawValue) ?? [],
        dependentOn: wire.dependentOn?.rawValue
      )
    )
  }

  static func pullRequestStatus(
    uri: String,
    cid: String?,
    value: UnknownATPValue
  ) throws(TangledError) -> TangledRecord<PullRequestStatusChange> {
    let wire: Sh.Tangled.Repo.PullStatus = try decode(value)
    return TangledRecord(
      uri: uri,
      cid: cid,
      value: PullRequestStatusChange(
        pullRequestURI: wire.pull.rawValue,
        status: PullRequestStatus(wireValue: wire.status.rawValue),
        createdAt: wire.createdAt
      )
    )
  }

  static func artifact(
    uri: String,
    cid: String?,
    value: UnknownATPValue
  ) throws(TangledError) -> TangledRecord<Artifact> {
    let wire: Sh.Tangled.RepoArtifact = try decode(value)
    guard let repositoryDID = wire.repoDid else {
      throw TangledError.decoding(ArtifactRecordDecodeError.missingRepositoryDID)
    }
    return try artifact(
      uri: uri,
      cid: cid,
      repositoryDID: repositoryDID.rawValue,
      tag: wire.tag,
      name: wire.name,
      blob: BlobReference(
        cid: wire.artifact.ref.toBaseEncodedString,
        mimeType: wire.artifact.mimeType,
        size: Int(wire.artifact.size)
      ),
      createdAt: wire.createdAt
    )
  }

  static func artifact(
    uri: String,
    cid: String?,
    repositoryDID: String,
    tag: Data,
    name: String,
    blob: BlobReference,
    createdAt: FormatString<Date>
  ) throws(TangledError) -> TangledRecord<Artifact> {
    guard tag.count == 20 else {
      throw TangledError.decoding(ArtifactRecordDecodeError.invalidTagLength(tag.count))
    }
    guard blob.size <= Artifact.maximumSize else {
      throw TangledError.upstreamFailed(
        "artifact \(uri) exceeds the 50 MiB limit"
      )
    }
    return TangledRecord(
      uri: uri,
      cid: cid,
      value: Artifact(
        repositoryDID: repositoryDID,
        tagObjectHash: tag.hexString,
        name: name,
        blob: blob,
        createdAt: createdAt
      )
    )
  }

  static func recordType(of value: UnknownATPValue) throws(TangledError) -> String {
    if case .record(let record) = value, let unknown = record as? UnknownRecord {
      return unknown.type
    }
    guard let type = value.type else {
      throw TangledError.decoding(UnknownRecordTypeError())
    }
    return type
  }

  private static func decode<Value: Decodable>(
    _ value: UnknownATPValue
  ) throws(TangledError) -> Value {
    do {
      let data = try JSONEncoder().encode(value)
      let decoder = JSONDecoder()
      decoder.userInfo[.atprotoLexiconDecodingMode] = LexiconDecodingMode.permissive
      return try decoder.decode(Value.self, from: data)
    } catch let error as TangledError {
      throw error
    } catch {
      throw TangledError.decoding(error)
    }
  }
}

private enum ArtifactRecordDecodeError: Error {
  case invalidTagLength(Int)
  case missingRepositoryDID
}

private struct UnknownRecordTypeError: Error {}
