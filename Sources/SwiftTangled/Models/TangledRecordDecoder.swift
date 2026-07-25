import Foundation
import SwiftAtproto
import TangledLexicons

enum TangledRecordDecoder {
  static func repository(
    uri: String,
    cid: String?,
    value: UnknownATPValue
  ) throws -> TangledRecord<Repository> {
    let wire: WireRepository = try decode(value)
    return TangledRecord(
      uri: uri,
      cid: cid,
      value: Repository(
        name: wire.name,
        knot: wire.knot,
        spindle: wire.spindle,
        description: wire.description,
        website: wire.website,
        topics: wire.topics ?? [],
        source: wire.source,
        labels: wire.labels ?? [],
        repoDID: wire.repoDid,
        createdAt: wire.createdAt
      )
    )
  }

  static func issue(
    uri: String,
    cid: String?,
    value: UnknownATPValue
  ) throws -> TangledRecord<Issue> {
    let wire: WireIssue = try decode(value)
    return TangledRecord(
      uri: uri,
      cid: cid,
      value: Issue(
        repositoryDID: wire.repo,
        title: wire.title,
        body: wire.body,
        createdAt: wire.createdAt,
        mentions: wire.mentions ?? [],
        references: wire.references ?? []
      )
    )
  }

  static func pullRequest(
    uri: String,
    cid: String?,
    value: UnknownATPValue
  ) throws -> TangledRecord<PullRequest> {
    let wire: WirePullRequest = try decode(value)
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
              cid: $0.patchBlob.ref.cid,
              mimeType: $0.patchBlob.mimeType,
              size: $0.patchBlob.size
            )
          )
        },
        source: wire.source.map {
          PullRequestSource(branch: $0.branch, repositoryDID: $0.repo)
        },
        target: PullRequestTarget(
          branch: wire.target.branch,
          repositoryDID: wire.target.repo
        ),
        createdAt: wire.createdAt,
        mentions: wire.mentions ?? [],
        references: wire.references ?? [],
        dependentOn: wire.dependentOn
      )
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
  ) throws -> TangledRecord<Artifact> {
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

  private static func decode<Value: Decodable>(_ value: UnknownATPValue) throws -> Value {
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

private struct WireRepository: Decodable {
  let name: String?
  let knot: String
  let spindle: String?
  let description: String?
  let website: String?
  let topics: [String]?
  let source: String?
  let labels: [String]?
  let repoDid: String?
  let createdAt: FormatString<Date>
}

private struct WireIssue: Decodable {
  let repo: String
  let title: String
  let body: String?
  let createdAt: FormatString<Date>
  let mentions: [String]?
  let references: [String]?
}

private struct WirePullRequest: Decodable {
  let title: String
  let body: String?
  let rounds: [WirePullRequestRound]
  let source: WirePullRequestSource?
  let target: WirePullRequestTarget
  let createdAt: FormatString<Date>
  let mentions: [String]?
  let references: [String]?
  let dependentOn: String?
}

private struct WirePullRequestSource: Decodable {
  let branch: String
  let repo: String?
}

private struct WirePullRequestTarget: Decodable {
  let branch: String
  let repo: String
}

private struct WirePullRequestRound: Decodable {
  let createdAt: FormatString<Date>
  let patchBlob: WirePullRequestBlob
}

private struct WirePullRequestBlob: Decodable {
  let ref: BobbinWireLink
  let mimeType: String
  let size: Int
}

private enum ArtifactRecordDecodeError: Error {
  case invalidTagLength(Int)
}
