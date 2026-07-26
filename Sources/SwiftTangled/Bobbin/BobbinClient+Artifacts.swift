import Foundation
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
  public func artifacts(
    repositoryDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    sort: ArtifactSortOrder = .desc
  ) async throws -> Page<TangledRecord<Artifact>> {
    try validateArtifactRepositoryDID(repositoryDID)
    try validateLimit(limit)
    let output = try await generatedQuery {
      try await RepoListArtifacts(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.RepoListArtifacts_Order(rawValue: sort.rawValue),
        subject: repositoryDID
      )
    }
    return Page(
      items: try output.items.map { item in
        let record: BobbinRecord<Sh.Tangled.RepoArtifact> = try generatedRecord(
          uri: item.uri,
          cid: item.cid,
          value: item.value
        )
        if let wireRepositoryDID = record.value.repoDid?.rawValue,
          wireRepositoryDID != repositoryDID
        {
          throw TangledError.upstreamFailed(
            "artifact \(item.uri) belongs to \(wireRepositoryDID), expected \(repositoryDID)"
          )
        }
        guard record.value.tag.count == 20 else {
          throw TangledError.upstreamFailed(
            "artifact \(item.uri) has a tag hash that is not 20 bytes"
          )
        }
        guard record.value.artifact.size <= Artifact.maximumSize else {
          throw TangledError.upstreamFailed(
            "artifact \(item.uri) exceeds the 50 MiB limit"
          )
        }
        return TangledRecord(
          uri: record.uri,
          cid: record.cid,
          value: Artifact(
            repositoryDID: repositoryDID,
            tagObjectHash: record.value.tag.hexString,
            name: record.value.name,
            blob: BlobReference(
              cid: record.value.artifact.ref.toBaseEncodedString,
              mimeType: record.value.artifact.mimeType,
              size: Int(record.value.artifact.size)
            ),
            createdAt: record.value.createdAt
          )
        )
      },
      cursor: output.cursor
    )
  }

  public func artifactCount(repositoryDID: String) async throws -> CountSummary {
    try validateArtifactRepositoryDID(repositoryDID)
    let output = try await generatedQuery {
      try await RepoCountArtifacts(subject: repositoryDID)
    }
    return CountSummary(count: output.count, distinctAuthors: output.distinctAuthors)
  }

  private func validateArtifactRepositoryDID(_ value: String) throws {
    guard FormatString<DID>(rawValue: value).typed != nil else {
      throw TangledError.invalidRequest("repository DID must be a valid DID")
    }
  }
}

extension Data {
  package var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
