import Foundation
import SwiftAtproto

public struct PullRequestResubmissionContext: Sendable {
  public let pullRequest: TangledRecord<PullRequest>

  let snapshot: PullRequestRecordSnapshot
  let latestPatch: Data
  let latestSourceRevision: String?
}

public struct PullRequestResubmissionResult: Codable, Equatable, Sendable {
  public let pullRequest: TangledRecord<PullRequest>
  public let roundNumber: Int

  public init(pullRequest: TangledRecord<PullRequest>, roundNumber: Int) {
    self.pullRequest = pullRequest
    self.roundNumber = roundNumber
  }
}

public struct PullRequestResubmissionService: Sendable {
  private let dependencies: PullRequestResubmissionDependencies

  public init(
    pdsRecordClient: PDSRecordClient = PDSRecordClient(),
    repositoryLocator: RepositoryLocator = RepositoryLocator()
  ) {
    let listService = AuthorPullRequestListService(pdsRecordClient: pdsRecordClient)
    let patchLoader = PullRequestPatchLoader(pdsRecordClient: pdsRecordClient)
    dependencies = PullRequestResubmissionDependencies(
      snapshot: { try await pdsRecordClient.pullRequestSnapshot(uri: $0) },
      repository: { try await repositoryLocator.resolve($0) },
      list: {
        try await listService.list(
          repositoryDID: $0,
          repositoryOwnerDID: $1,
          authorDID: $2,
          cursor: $3,
          limit: 1_000,
          order: .ascending
        )
      },
      patch: { try await patchLoader.load(record: $0).rawPatch },
      appendRound: { try await $2.appendPullRequestRound(current: $0, patch: $1) }
    )
  }

  init(dependencies: PullRequestResubmissionDependencies) {
    self.dependencies = dependencies
  }

  public func prepare(
    pullRequestURI: String
  ) async throws -> PullRequestResubmissionContext {
    let snapshot = try await dependencies.snapshot(pullRequestURI)
    let record = snapshot.record
    guard record.uri == pullRequestURI else {
      throw TangledError.upstreamFailed(
        "PDS returned a different pull request record: \(record.uri)"
      )
    }
    let authorDID = try ownerDID(record.uri, name: "pull request")
    let pull = record.value
    guard let source = pull.source else {
      throw TangledError.invalidRequest(
        "patch-based pull request resubmission is not supported yet"
      )
    }
    guard source.repositoryDID == nil else {
      throw TangledError.invalidRequest(
        "fork-based pull request resubmission is not supported yet"
      )
    }
    guard pull.dependentOn == nil else {
      throw TangledError.invalidRequest(
        "stacked pull request resubmission is not supported yet"
      )
    }
    guard !pull.rounds.isEmpty else {
      throw TangledError.invalidRequest("pull request does not contain a round")
    }

    let repository = try await dependencies.repository(pull.target.repositoryDID)
    guard repository.value.repoDID == pull.target.repositoryDID else {
      throw TangledError.upstreamFailed(
        "repository record does not match pull request target"
      )
    }
    let repositoryOwnerDID = try ownerDID(repository.uri, name: "repository")
    let items = try await allPullRequests(
      repositoryDID: pull.target.repositoryDID,
      repositoryOwnerDID: repositoryOwnerDID,
      authorDID: authorDID
    )
    guard let current = items.first(where: { $0.record.uri == record.uri }) else {
      throw TangledError.notFound("pull request is not present in the author PDS listing")
    }
    guard current.record.cid == record.cid else {
      throw TangledError.conflict("pull request changed while validating its status")
    }
    guard current.status == .open else {
      throw TangledError.invalidRequest(
        "pull request is not open: \(current.status.rawValue)"
      )
    }
    guard !items.contains(where: { $0.record.value.dependentOn == record.uri }) else {
      throw TangledError.invalidRequest(
        "stacked pull request resubmission is not supported yet"
      )
    }

    let latestPatch = try await dependencies.patch(record)
    return PullRequestResubmissionContext(
      pullRequest: record,
      snapshot: snapshot,
      latestPatch: latestPatch,
      latestSourceRevision: sourceRevision(in: latestPatch)
    )
  }

  public func resubmit(
    _ context: PullRequestResubmissionContext,
    patch: Data,
    sourceRevision: String,
    pdsClient: PDSClient
  ) async throws -> PullRequestResubmissionResult {
    guard !patch.isEmpty else {
      throw TangledError.invalidRequest("pull request patch must not be empty")
    }
    guard patch != context.latestPatch else {
      throw TangledError.invalidRequest("patch is identical to the latest round")
    }
    if let previous = context.latestSourceRevision,
      revisionsMatch(previous, sourceRevision)
    {
      throw TangledError.invalidRequest(
        "source branch has not changed since the latest round"
      )
    }
    let roundNumber = context.pullRequest.value.rounds.count
    let record = try await dependencies.appendRound(context.snapshot, patch, pdsClient)
    return PullRequestResubmissionResult(
      pullRequest: record,
      roundNumber: roundNumber
    )
  }
}

struct PullRequestResubmissionDependencies: Sendable {
  let snapshot: @Sendable (String) async throws -> PullRequestRecordSnapshot
  let repository: @Sendable (String) async throws -> TangledRecord<Repository>
  let list: @Sendable (String, String, String, String?) async throws -> Page<PullRequestListItem>
  let patch: @Sendable (TangledRecord<PullRequest>) async throws -> Data
  let appendRound:
    @Sendable (PullRequestRecordSnapshot, Data, PDSClient) async throws ->
      TangledRecord<PullRequest>
}

extension PullRequestResubmissionService {
  private func allPullRequests(
    repositoryDID: String,
    repositoryOwnerDID: String,
    authorDID: String
  ) async throws -> [PullRequestListItem] {
    var items: [PullRequestListItem] = []
    var cursor: String?
    var seen = Set<String>()
    repeat {
      let page = try await dependencies.list(
        repositoryDID,
        repositoryOwnerDID,
        authorDID,
        cursor
      )
      items.append(contentsOf: page.items)
      guard let next = page.cursor else { break }
      guard seen.insert(next).inserted else {
        throw TangledError.upstreamFailed(
          "PDS returned a repeated pull request pagination cursor"
        )
      }
      cursor = next
    } while true
    return items
  }

  private func ownerDID(_ rawURI: String, name: String) throws -> String {
    let uri: ATURI
    do {
      uri = try ATURI(string: rawURI)
    } catch {
      throw TangledError.decoding(PullRequestResubmissionError.invalidRecordURI(rawURI))
    }
    guard case .did(let did) = uri.authority else {
      throw TangledError.decoding(PullRequestResubmissionError.invalidRecordURI(rawURI))
    }
    guard uri.rkey != nil else {
      throw TangledError.decoding(
        PullRequestResubmissionError.missingRecordKey(name)
      )
    }
    return did.rawValue
  }

  private func sourceRevision(in patch: Data) -> String? {
    let envelopePrefix = "From "
    // git format-patch uses this fixed mbox separator timestamp; it is not the commit date.
    let envelopeSuffix = " Mon Sep 17 00:00:00 2001"

    return String(decoding: patch, as: UTF8.self)
      .split(separator: "\n")
      .reversed()
      .first { line in
        guard line.hasPrefix(envelopePrefix), line.hasSuffix(envelopeSuffix) else {
          return false
        }
        let revision = line.dropFirst(envelopePrefix.count).dropLast(envelopeSuffix.count)
        return revision.count >= 7 && revision.allSatisfy(\.isHexDigit)
      }
      .map {
        String($0.dropFirst(envelopePrefix.count).dropLast(envelopeSuffix.count))
      }
  }

  private func revisionsMatch(_ previous: String, _ current: String) -> Bool {
    previous == current
      || (previous.count >= 7 && current.hasPrefix(previous))
      || (current.count >= 7 && previous.hasPrefix(current))
  }
}

private enum PullRequestResubmissionError: Error {
  case invalidRecordURI(String)
  case missingRecordKey(String)
}
