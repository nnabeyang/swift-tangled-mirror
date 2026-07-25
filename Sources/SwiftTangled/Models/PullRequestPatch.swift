import Foundation
import SwiftAtproto

public struct PullRequestPatch: Codable, Equatable, Hashable, Sendable {
  public let pullRequestURI: String
  /// The zero-based round number used by Tangled Web.
  public let roundNumber: Int
  public let totalRounds: Int
  public let createdAt: FormatString<Date>
  public let blob: BlobReference
  public let rawPatch: Data
  public let unifiedDiff: Data

  public init(
    pullRequestURI: String,
    roundNumber: Int,
    totalRounds: Int,
    createdAt: FormatString<Date>,
    blob: BlobReference,
    rawPatch: Data,
    unifiedDiff: Data
  ) {
    self.pullRequestURI = pullRequestURI
    self.roundNumber = roundNumber
    self.totalRounds = totalRounds
    self.createdAt = createdAt
    self.blob = blob
    self.rawPatch = rawPatch
    self.unifiedDiff = unifiedDiff
  }
}
