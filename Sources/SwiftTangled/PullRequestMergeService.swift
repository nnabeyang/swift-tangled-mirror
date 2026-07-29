import Foundation
import SwiftAtproto

public struct PullRequestMergeService: Sendable {
  private let dependencies: PullRequestMergeDependencies

  public init(
    bobbinClient: BobbinClient = BobbinClient(),
    repositoryLocator: RepositoryLocator? = nil,
    patchLoader: PullRequestPatchLoader? = nil,
    knotClient: KnotClient = KnotClient()
  ) {
    let repositoryLocator = repositoryLocator ?? RepositoryLocator(client: bobbinClient)
    let pdsRecordClient = PDSRecordClient()
    let patchLoader = patchLoader ?? PullRequestPatchLoader(pdsRecordClient: pdsRecordClient)
    self.dependencies = PullRequestMergeDependencies(
      pullRequest: { try await pdsRecordClient.pullRequest(uri: $0) },
      indexedState: { uri in
        async let record = bobbinClient.pullRequest(uri: uri)
        async let statuses = bobbinClient.pullRequestStatuses(
          pullRequestURI: uri,
          limit: 1
        )
        return try await PullRequestIndexedState(
          record: record,
          status: statuses.items.first?.value.status ?? .open
        )
      },
      patch: { try await patchLoader.load(record: $0).rawPatch },
      repository: { try await repositoryLocator.resolve($0) },
      mergeCheck: {
        try await knotClient.mergeCheck(
          knot: $0,
          ownerDID: $1,
          repositoryName: $2,
          repositoryDID: $3,
          branch: $4,
          patch: $5
        )
      },
      merge: {
        try await knotClient.merge(
          knot: $0,
          token: $1,
          ownerDID: $2,
          repositoryName: $3,
          repositoryDID: $4,
          branch: $5,
          patch: $6,
          commitMessage: $7,
          commitBody: $8
        )
      },
      serviceAuthToken: { client, audience, lxm in
        try await client.serviceAuthToken(audience: audience, lxm: lxm)
      },
      markPullRequestsMerged: { client, uris in
        try await client.markPullRequestsMerged(uris)
      }
    )
  }

  init(dependencies: PullRequestMergeDependencies) {
    self.dependencies = dependencies
  }

  public func check(pullRequestURI: String) async throws -> PullRequestMergeCheck {
    let prepared = try await prepare(
      pullRequestURI: pullRequestURI,
      requireFreshIndexedState: false
    )
    return try await check(prepared)
  }

  public func merge(
    pullRequestURI: String,
    allowStack: Bool,
    pdsClient: PDSClient
  ) async throws -> PullRequestMergeResult {
    let prepared = try await prepare(
      pullRequestURI: pullRequestURI,
      requireFreshIndexedState: true
    )
    if prepared.pullRequestURIs.count > 1, !allowStack {
      throw TangledError.invalidRequest(
        "merge includes stacked pull requests: "
          + prepared.pullRequestURIs.joined(separator: ", ")
          + "; rerun with --stack"
      )
    }
    let mergeCheck = try await check(prepared)
    guard mergeCheck.error == nil else {
      throw TangledError.upstreamFailed("merge check failed: \(mergeCheck.error!)")
    }
    guard !mergeCheck.isConflicted else {
      let files = mergeCheck.conflicts.map(\.filename).joined(separator: ", ")
      throw TangledError.invalidRequest(
        files.isEmpty ? "pull request has merge conflicts" : "merge conflicts: \(files)"
      )
    }
    try await validateFreshMergeState(prepared)

    let audience = try knotServiceAudience(prepared.repository.value.knot)
    let token = try await dependencies.serviceAuthToken(
      pdsClient,
      audience,
      "sh.tangled.repo.merge"
    )
    try await dependencies.merge(
      prepared.repository.value.knot,
      token,
      prepared.ownerDID,
      prepared.repositoryName,
      prepared.repositoryDID,
      prepared.targetBranch,
      prepared.patch,
      prepared.title,
      prepared.body
    )
    do {
      let statuses = try await dependencies.markPullRequestsMerged(
        pdsClient,
        prepared.pullRequestURIs
      )
      return PullRequestMergeResult(check: mergeCheck, statusRecords: statuses)
    } catch {
      return PullRequestMergeResult(
        check: mergeCheck,
        statusRecords: [],
        outcome: .mergedStatusRecordsFailed,
        statusRecordError: String(describing: error)
      )
    }
  }
}

struct PullRequestMergeDependencies: Sendable {
  let pullRequest: @Sendable (String) async throws -> TangledRecord<PullRequest>
  let indexedState: @Sendable (String) async throws -> PullRequestIndexedState
  let patch: @Sendable (TangledRecord<PullRequest>) async throws -> Data
  let repository: @Sendable (String) async throws -> TangledRecord<Repository>
  let mergeCheck:
    @Sendable (String, String, String, String, String, String) async throws ->
      PullRequestMergeCheckResponse
  let merge:
    @Sendable (String, String, String, String, String, String, String, String, String?) async throws
      ->
      Void
  let serviceAuthToken: @Sendable (PDSClient, String, String) async throws -> String
  let markPullRequestsMerged: @Sendable (PDSClient, [String]) async throws -> [TangledRecord<PullRequestStatusChange>]
}

struct PullRequestIndexedState: Sendable {
  let record: TangledRecord<PullRequest>
  let status: PullRequestStatus
}

private struct PreparedPullRequestMerge: Sendable {
  let pullRequestURIs: [String]
  let pullRequestCIDs: [String: String]
  let repository: TangledRecord<Repository>
  let ownerDID: String
  let repositoryName: String
  let repositoryDID: String
  let targetBranch: String
  let patch: String
  let title: String
  let body: String?
}

extension PullRequestMergeService {
  private func prepare(
    pullRequestURI: String,
    requireFreshIndexedState: Bool
  ) async throws -> PreparedPullRequestMerge {
    var records: [TangledRecord<PullRequest>] = []
    var nextURI: String? = pullRequestURI
    var seen = Set<String>()

    while let uri = nextURI {
      guard seen.insert(uri).inserted else {
        throw TangledError.invalidRequest("circular pull request dependency: \(uri)")
      }
      let record = try await dependencies.pullRequest(uri)
      if requireFreshIndexedState {
        let indexedState = try await dependencies.indexedState(uri)
        try validate(indexedState: indexedState, matches: record)
        if records.isEmpty {
          guard indexedState.status == .open else {
            throw TangledError.invalidRequest("pull request is not open: \(uri)")
          }
        } else if indexedState.status == .merged || indexedState.status == .closed {
          break
        } else if indexedState.status != .open {
          throw TangledError.invalidRequest(
            "unsupported pull request status \(indexedState.status.rawValue): \(uri)"
          )
        }
      }
      records.append(record)
      nextURI = record.value.dependentOn
    }
    guard let selected = records.first else {
      throw TangledError.notFound("no mergeable pull request")
    }

    let repositoryDID = selected.value.target.repositoryDID
    let targetBranch = selected.value.target.branch
    for record in records {
      guard record.value.target.repositoryDID == repositoryDID,
        record.value.target.branch == targetBranch
      else {
        throw TangledError.invalidRequest(
          "stacked pull requests must share a target repository and branch"
        )
      }
    }
    let repository = try await dependencies.repository(repositoryDID)
    guard repository.value.repoDID == repositoryDID else {
      throw TangledError.upstreamFailed("repository record does not match pull request target")
    }
    let uri = try ATURI(string: repository.uri)
    guard case .did(let ownerDID) = uri.authority,
      let rkey = uri.rkey?.rawValue
    else {
      throw TangledError.decoding(PullRequestMergeServiceError.invalidRepositoryURI)
    }
    let name = repository.value.name ?? rkey

    var patches: [String] = []
    for record in records.reversed() {
      let data = try await dependencies.patch(record)
      guard let patch = String(data: data, encoding: .utf8) else {
        throw TangledError.decoding(PullRequestMergeServiceError.nonUTF8Patch)
      }
      patches.append(patch)
    }
    return PreparedPullRequestMerge(
      pullRequestURIs: records.map(\.uri),
      pullRequestCIDs: try Dictionary(
        uniqueKeysWithValues: records.map { record in
          guard let cid = record.cid, !cid.isEmpty else {
            throw TangledError.invalidRequest(
              "pull request does not expose a CID: \(record.uri)"
            )
          }
          return (record.uri, cid)
        }
      ),
      repository: repository,
      ownerDID: ownerDID.rawValue,
      repositoryName: name,
      repositoryDID: repositoryDID,
      targetBranch: targetBranch,
      patch: patches.joined(separator: "\n"),
      title: selected.value.title,
      body: selected.value.body
    )
  }

  private func validateFreshMergeState(_ prepared: PreparedPullRequestMerge) async throws {
    for uri in prepared.pullRequestURIs {
      let record = try await dependencies.pullRequest(uri)
      guard record.cid == prepared.pullRequestCIDs[uri] else {
        throw TangledError.invalidRequest(
          "pull request changed during merge check: \(uri); rerun the merge"
        )
      }
      let indexedState = try await dependencies.indexedState(uri)
      try validate(indexedState: indexedState, matches: record)
      guard indexedState.status == .open else {
        throw TangledError.invalidRequest("pull request is not open: \(uri)")
      }
    }
  }

  private func validate(
    indexedState: PullRequestIndexedState,
    matches authoritativeRecord: TangledRecord<PullRequest>
  ) throws {
    guard let authoritativeCID = authoritativeRecord.cid, !authoritativeCID.isEmpty else {
      throw TangledError.invalidRequest(
        "pull request does not expose a CID: \(authoritativeRecord.uri)"
      )
    }
    guard indexedState.record.uri == authoritativeRecord.uri,
      indexedState.record.cid == authoritativeCID
    else {
      throw TangledError.upstreamFailed(
        "pull request state is not indexed for the latest record: "
          + "\(authoritativeRecord.uri); retry after Bobbin catches up"
      )
    }
  }

  private func check(_ prepared: PreparedPullRequestMerge) async throws
    -> PullRequestMergeCheck
  {
    let response = try await dependencies.mergeCheck(
      prepared.repository.value.knot,
      prepared.ownerDID,
      prepared.repositoryName,
      prepared.repositoryDID,
      prepared.targetBranch,
      prepared.patch
    )
    return PullRequestMergeCheck(
      pullRequestURIs: prepared.pullRequestURIs,
      repositoryDID: prepared.repositoryDID,
      targetBranch: prepared.targetBranch,
      isConflicted: response.isConflicted,
      conflicts: response.conflicts,
      message: response.message,
      error: response.error
    )
  }

}

private enum PullRequestMergeServiceError: Error, Sendable {
  case invalidRepositoryURI
  case nonUTF8Patch
}
