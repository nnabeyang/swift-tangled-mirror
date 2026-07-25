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
    let output: WireArtifactPage = try await get(
      nsid: Sh.Tangled.RepoListArtifacts.id,
      queryItems: [
        URLQueryItem(name: "cursor", value: cursor),
        URLQueryItem(name: "limit", value: limit.map(String.init)),
        URLQueryItem(name: "order", value: sort.rawValue),
        URLQueryItem(name: "subject", value: repositoryDID),
      ].filter { $0.value != nil }
    )
    return Page(
      items: try output.items.map { item in
        if let wireRepositoryDID = item.value.repoDid,
          wireRepositoryDID != repositoryDID
        {
          throw TangledError.upstreamFailed(
            "artifact \(item.uri) belongs to \(wireRepositoryDID), expected \(repositoryDID)"
          )
        }
        guard item.value.tag.count == 20 else {
          throw TangledError.upstreamFailed(
            "artifact \(item.uri) has a tag hash that is not 20 bytes"
          )
        }
        guard item.value.artifact.size <= Artifact.maximumSize else {
          throw TangledError.upstreamFailed(
            "artifact \(item.uri) exceeds the 50 MiB limit"
          )
        }
        return TangledRecord(
          uri: item.uri,
          cid: item.cid,
          value: Artifact(
            repositoryDID: repositoryDID,
            tagObjectHash: item.value.tag.hexString,
            name: item.value.name,
            blob: BlobReference(
              cid: item.value.artifact.ref.toBaseEncodedString,
              mimeType: item.value.artifact.mimeType,
              size: Int(item.value.artifact.size)
            ),
            createdAt: item.value.createdAt
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

private struct WireArtifactPage: Decodable {
  let cursor: String?
  let items: [WireArtifactItem]
}

private struct WireArtifactItem: Decodable {
  let uri: String
  let cid: String?
  let value: WireArtifact
}

private struct WireArtifact: Decodable {
  let artifact: LexBlob
  let createdAt: FormatString<Date>
  let name: String
  let repoDid: String?
  let tag: Data

  private enum CodingKeys: String, CodingKey {
    case artifact, createdAt, name, repoDid, tag
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    artifact = try container.decode(LexBlob.self, forKey: .artifact)
    createdAt = try container.decode(FormatString<Date>.self, forKey: .createdAt)
    name = try container.decode(String.self, forKey: .name)
    repoDid = try container.decodeIfPresent(String.self, forKey: .repoDid)
    tag = try container.decode(ArtifactBytes.self, forKey: .tag).data
  }
}

private struct ArtifactBytes: Decodable {
  let data: Data

  private enum CodingKeys: String, CodingKey {
    case bytes = "$bytes"
  }

  init(from decoder: any Decoder) throws {
    if let value = try? decoder.singleValueContainer().decode(String.self) {
      data = try Self.decode(value, codingPath: decoder.codingPath)
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    data = try Self.decode(
      container.decode(String.self, forKey: .bytes),
      codingPath: decoder.codingPath
    )
  }

  private static func decode(_ value: String, codingPath: [any CodingKey]) throws -> Data {
    let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let data = Data(base64Encoded: value + padding) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: codingPath, debugDescription: "invalid AT Protocol bytes value")
      )
    }
    return data
  }
}

extension Data {
  package var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
