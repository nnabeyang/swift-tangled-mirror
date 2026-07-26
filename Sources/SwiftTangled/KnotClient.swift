import Foundation
import SwiftAtproto
import TangledLexicons

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct KnotClient: Sendable {
  private let transport: any HTTPTransport

  public init(transport: any HTTPTransport = URLSessionTransport()) {
    self.transport = transport
  }

  public func mergeCheck(
    knot: String,
    ownerDID: String,
    repositoryName: String,
    repositoryDID: String,
    branch: String,
    patch: String
  ) async throws -> PullRequestMergeCheckResponse {
    let input = Sh.Tangled.RepoMergeCheck_Input(
      branch: branch,
      did: FormatString(rawValue: ownerDID),
      name: repositoryName,
      patch: patch,
      repo: FormatString(rawValue: repositoryDID)
    )
    let output = try await client(knot: knot).RepoMergeCheck(input: input)
    return PullRequestMergeCheckResponse(
      isConflicted: output.is_conflicted,
      conflicts: (output.conflicts ?? []).map {
        PullRequestMergeConflict(filename: $0.filename, reason: $0.reason)
      },
      message: output.message,
      error: output.error
    )
  }

  public func merge(
    knot: String,
    token: String,
    ownerDID: String,
    repositoryName: String,
    repositoryDID: String,
    branch: String,
    patch: String,
    commitMessage: String,
    commitBody: String?
  ) async throws {
    let input = Sh.Tangled.RepoMerge_Input(
      branch: branch,
      commitBody: commitBody,
      commitMessage: commitMessage,
      did: FormatString(rawValue: ownerDID),
      name: repositoryName,
      patch: patch,
      repo: FormatString(rawValue: repositoryDID)
    )
    _ = try await client(knot: knot, token: token).RepoMerge(input: input)
  }
}

public struct PullRequestMergeCheckResponse: Equatable, Sendable {
  public let isConflicted: Bool
  public let conflicts: [PullRequestMergeConflict]
  public let message: String?
  public let error: String?

  public init(
    isConflicted: Bool,
    conflicts: [PullRequestMergeConflict] = [],
    message: String? = nil,
    error: String? = nil
  ) {
    self.isConflicted = isConflicted
    self.conflicts = conflicts
    self.message = message
    self.error = error
  }
}

extension KnotClient {
  fileprivate func client(
    knot: String,
    token: String? = nil
  ) throws -> HTTPXRPCClient {
    HTTPXRPCClient(
      baseURL: try knotBaseURL(knot),
      transport: transport,
      bearerToken: token
    )
  }

  fileprivate func knotBaseURL(_ value: String) throws -> URL {
    let rawValue = value.contains("://") ? value : "https://\(value)"
    guard let url = URL(string: rawValue),
      url.scheme?.lowercased() == "https",
      url.host != nil
    else {
      throw TangledError.invalidRequest("invalid Knot endpoint: \(value)")
    }
    return url
  }
}
