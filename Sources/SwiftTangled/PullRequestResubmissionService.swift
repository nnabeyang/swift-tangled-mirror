import Foundation
import SwiftAtproto

public struct PullRequestResubmissionContext: Sendable {
  public let pullRequest: TangledRecord<PullRequest>

  let snapshot: PullRequestRecordSnapshot
  let latestPatch: Data
  let latestSourceRevision: String?
  let fork: ForkPullRequestResubmissionContext?
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
    repositoryLocator: RepositoryLocator = RepositoryLocator(),
    knotClient: KnotClient = KnotClient()
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
      updateHiddenRef: {
        try await knotClient.updateHiddenRef(
          knot: $0,
          token: $1,
          repositoryURI: $2,
          sourceBranch: $3,
          targetBranch: $4
        )
      },
      compare: {
        try await knotClient.compare(
          knot: $0,
          repositoryDID: $1,
          baseRevision: $2,
          headRevision: $3
        )
      },
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
    let fork = try await forkContext(pull: pull, targetRepository: repository)
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
      latestSourceRevision: pull.source == nil ? nil : sourceRevision(in: latestPatch),
      fork: fork
    )
  }

  public func resubmit(
    _ context: PullRequestResubmissionContext,
    patch: Data,
    sourceRevision: String,
    pdsClient: PDSClient
  ) async throws -> PullRequestResubmissionResult {
    guard let source = context.pullRequest.value.source else {
      throw TangledError.invalidRequest(
        "source revision is only valid for branch-based pull requests"
      )
    }
    guard source.repositoryDID == nil else {
      throw TangledError.invalidRequest(
        "fork-based pull requests must use fork resubmission"
      )
    }
    try validateChangedPatch(patch, context: context)
    if let previous = context.latestSourceRevision,
      revisionsMatch(previous, sourceRevision)
    {
      throw TangledError.invalidRequest(
        "source branch has not changed since the latest round"
      )
    }
    return try await append(patch, to: context, pdsClient: pdsClient)
  }

  public func resubmitFork(
    _ context: PullRequestResubmissionContext,
    pdsClient: PDSClient
  ) async throws -> PullRequestResubmissionResult {
    guard let source = context.pullRequest.value.source,
      let sourceRepositoryDID = source.repositoryDID,
      let fork = context.fork
    else {
      throw TangledError.invalidRequest(
        "fork resubmission is only valid for fork-based pull requests"
      )
    }
    let audience = try knotServiceAudience(fork.repository.value.knot)
    let token = try await pdsClient.serviceAuthToken(
      audience: audience,
      lxm: "sh.tangled.repo.hiddenRef"
    )
    let hiddenRef = try await dependencies.updateHiddenRef(
      fork.repository.value.knot,
      token,
      fork.repository.uri,
      source.branch,
      context.pullRequest.value.target.branch
    )
    let comparison = try await dependencies.compare(
      fork.repository.value.knot,
      sourceRepositoryDID,
      hiddenRef,
      source.branch
    )
    let patch = Data(comparison.patch.utf8)
    try validateChangedPatch(patch, context: context)
    if let previous = context.latestSourceRevision,
      revisionsMatch(previous, comparison.headRevision)
    {
      throw TangledError.invalidRequest(
        "source branch has not changed since the latest round"
      )
    }
    return try await append(patch, to: context, pdsClient: pdsClient)
  }

  public func resubmit(
    _ context: PullRequestResubmissionContext,
    patch: Data,
    pdsClient: PDSClient
  ) async throws -> PullRequestResubmissionResult {
    guard context.pullRequest.value.source == nil else {
      throw TangledError.invalidRequest(
        "patch files are only valid for patch-based pull requests"
      )
    }
    let normalizedPatch = try normalizedPatch(patch)
    try validateChangedPatch(normalizedPatch, context: context)
    return try await append(normalizedPatch, to: context, pdsClient: pdsClient)
  }

  private func append(
    _ patch: Data,
    to context: PullRequestResubmissionContext,
    pdsClient: PDSClient
  ) async throws -> PullRequestResubmissionResult {
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
  let updateHiddenRef: @Sendable (String, String, String, String, String) async throws -> String
  let compare: @Sendable (String, String, String, String) async throws -> GitComparison
  let appendRound:
    @Sendable (PullRequestRecordSnapshot, Data, PDSClient) async throws ->
      TangledRecord<PullRequest>
}

struct ForkPullRequestResubmissionContext: Sendable {
  let repository: TangledRecord<Repository>
}

extension PullRequestResubmissionService {
  private func forkContext(
    pull: PullRequest,
    targetRepository: TangledRecord<Repository>
  ) async throws -> ForkPullRequestResubmissionContext? {
    guard let sourceRepositoryDID = pull.source?.repositoryDID else {
      return nil
    }
    guard sourceRepositoryDID != pull.target.repositoryDID else {
      throw TangledError.invalidRequest(
        "fork source repository must differ from the target repository"
      )
    }
    let sourceRepository = try await dependencies.repository(sourceRepositoryDID)
    guard sourceRepository.value.repoDID == sourceRepositoryDID else {
      throw TangledError.upstreamFailed(
        "repository record does not match pull request source"
      )
    }
    guard let upstreamReference = sourceRepository.value.source else {
      throw TangledError.invalidRequest(
        "source repository is not declared as a fork"
      )
    }
    let upstreamRepository = try await dependencies.repository(upstreamReference)
    guard upstreamRepository.value.repoDID == pull.target.repositoryDID,
      upstreamRepository.uri == targetRepository.uri
    else {
      throw TangledError.invalidRequest(
        "source repository fork metadata points to a different target repository"
      )
    }
    return ForkPullRequestResubmissionContext(repository: sourceRepository)
  }

  private func validateChangedPatch(
    _ patch: Data,
    context: PullRequestResubmissionContext
  ) throws {
    guard !patch.isEmpty else {
      throw TangledError.invalidRequest("pull request patch must not be empty")
    }
    guard patch != context.latestPatch else {
      throw TangledError.invalidRequest("patch is identical to the latest round")
    }
  }

  private func normalizedPatch(_ patch: Data) throws -> Data {
    guard let text = String(data: patch, encoding: .utf8) else {
      throw TangledError.invalidRequest("pull request patch must be valid UTF-8")
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count >= 2 else {
      throw TangledError.invalidRequest(
        "pull request patch must be a git diff or git format-patch"
      )
    }

    let firstLine = lines[0].trimmingCharacters(in: .whitespaces)
    let diffPrefixes = ["diff ", "--- ", "Index: ", "+++ ", "@@ "]
    if diffPrefixes.contains(where: firstLine.hasPrefix) {
      return text.hasSuffix("\n") ? patch : Data("\(text)\n".utf8)
    }

    let envelopeSuffix = " Mon Sep 17 00:00:00 2001"
    guard firstLine.hasPrefix("From "), firstLine.hasSuffix(envelopeSuffix),
      lines.contains(where: { $0.hasPrefix("From: ") }),
      lines.contains(where: { $0.hasPrefix("Subject: ") }),
      lines.contains(where: {
        let line = $0.trimmingCharacters(in: .whitespaces)
        return diffPrefixes.contains(where: line.hasPrefix)
      })
    else {
      throw TangledError.invalidRequest(
        "pull request patch must be a git diff or git format-patch"
      )
    }
    let revision = firstLine.dropFirst("From ".count).dropLast(envelopeSuffix.count)
    guard revision.count >= 7, revision.allSatisfy(\.isHexDigit) else {
      throw TangledError.invalidRequest(
        "pull request patch must be a git diff or git format-patch"
      )
    }
    return patch
  }

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
