import Foundation
import SwiftAtproto

public struct Artifact: Codable, Equatable, Hashable, Sendable {
  public static let maximumSize = 50 * 1024 * 1024

  public let repositoryDID: String
  public let tagObjectHash: String
  public let name: String
  public let blob: BlobReference
  public let createdAt: FormatString<Date>

  public init(
    repositoryDID: String,
    tagObjectHash: String,
    name: String,
    blob: BlobReference,
    createdAt: FormatString<Date>
  ) {
    self.repositoryDID = repositoryDID
    self.tagObjectHash = tagObjectHash
    self.name = name
    self.blob = blob
    self.createdAt = createdAt
  }
}

public enum ArtifactSortOrder: String, Codable, Equatable, Hashable, Sendable {
  case asc
  case desc
}

public struct ArtifactTagView: Codable, Equatable, Sendable {
  public let tag: GitTag
  public let artifacts: [TangledRecord<Artifact>]

  public init(tag: GitTag, artifacts: [TangledRecord<Artifact>]) {
    self.tag = tag
    self.artifacts = artifacts
  }
}

public struct ArtifactDownloadResult: Codable, Equatable, Sendable {
  public let record: TangledRecord<Artifact>
  public let destinationURL: URL
  public let byteCount: Int64
  public let verifiedCID: String

  public init(
    record: TangledRecord<Artifact>,
    destinationURL: URL,
    byteCount: Int64,
    verifiedCID: String
  ) {
    self.record = record
    self.destinationURL = destinationURL
    self.byteCount = byteCount
    self.verifiedCID = verifiedCID
  }
}

public enum ArtifactError: Error, Equatable, Sendable {
  case invalidName(String)
  case fileTooLarge(maximumBytes: Int64, actualBytes: Int64?)
  case tagNotAnnotated(String)
  case alreadyExists(uri: String)
  case notOwned(uri: String)
  case invalidBlobCID(String)
  case checksumMismatch(expectedCID: String, actualDigest: String)
  case unsafeDestination(String)
}
