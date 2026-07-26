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
    let patchLoader = patchLoader ?? PullRequestPatchLoader()
    self.dependencies = PullRequestMergeDependencies(
      pullRequest: { try await bobbinClient.pullRequest(uri: $0) },
      pullRequestStatus: { uri in
        try await bobbinClient.pullRequestStatuses(
          pullRequestURI: uri,
          limit: 1
        ).items.first?.value.status ?? .open
      },
      patch: { try await patchLoader.load(pullRequestURI: $0).rawPatch },
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
      }
    )
  }

  init(dependencies: PullRequestMergeDependencies) {
    self.dependencies = dependencies
  }

  public func check(pullRequestURI: String) async throws -> PullRequestMergeCheck {
    let prepared = try await prepare(pullRequestURI: pullRequestURI)
    return try await check(prepared)
  }

  public func merge(
    pullRequestURI: String,
    allowStack: Bool,
    pdsClient: PDSClient
  ) async throws -> PullRequestMergeResult {
    let prepared = try await prepare(pullRequestURI: pullRequestURI)
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

    let audience = try knotAudience(prepared.repository.value.knot)
    let token = try await pdsClient.serviceAuthToken(
      audience: audience,
      lxm: "sh.tangled.repo.merge"
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
      let statuses = try await pdsClient.markPullRequestsMerged(prepared.pullRequestURIs)
      return PullRequestMergeResult(check: mergeCheck, statusRecords: statuses)
    } catch {
      throw TangledError.upstreamFailed(
        "merge succeeded for \(prepared.pullRequestURIs.joined(separator: ", ")), "
          + "but merged status records failed: \(error)"
      )
    }
  }
}

struct PullRequestMergeDependencies: Sendable {
  let pullRequest: @Sendable (String) async throws -> TangledRecord<PullRequest>
  let pullRequestStatus: @Sendable (String) async throws -> PullRequestStatus
  let patch: @Sendable (String) async throws -> Data
  let repository: @Sendable (String) async throws -> TangledRecord<Repository>
  let mergeCheck:
    @Sendable (String, String, String, String, String, String) async throws ->
      PullRequestMergeCheckResponse
  let merge:
    @Sendable (String, String, String, String, String, String, String, String, String?) async throws
      ->
      Void
}

private struct PreparedPullRequestMerge: Sendable {
  let pullRequestURIs: [String]
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
  private func prepare(pullRequestURI: String) async throws -> PreparedPullRequestMerge {
    var records: [TangledRecord<PullRequest>] = []
    var nextURI: String? = pullRequestURI
    var seen = Set<String>()

    while let uri = nextURI {
      guard seen.insert(uri).inserted else {
        throw TangledError.invalidRequest("circular pull request dependency: \(uri)")
      }
      let record = try await dependencies.pullRequest(uri)
      let status = try await dependencies.pullRequestStatus(uri)
      if records.isEmpty {
        guard status == .open else {
          throw TangledError.invalidRequest("pull request is not open: \(uri)")
        }
      } else if status == .merged || status == .closed {
        break
      } else if status != .open {
        throw TangledError.invalidRequest(
          "unsupported pull request status \(status.rawValue): \(uri)"
        )
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
      let data = try await dependencies.patch(record.uri)
      guard let patch = String(data: data, encoding: .utf8) else {
        throw TangledError.decoding(PullRequestMergeServiceError.nonUTF8Patch)
      }
      patches.append(patch)
    }
    return PreparedPullRequestMerge(
      pullRequestURIs: records.map(\.uri),
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

  private func knotAudience(_ knot: String) throws -> String {
    let rawValue = knot.contains("://") ? knot : "https://\(knot)"
    guard let url = URL(string: rawValue),
      url.scheme?.lowercased() == "https",
      let host = url.host,
      url.path.isEmpty || url.path == "/"
    else {
      throw TangledError.invalidRequest("invalid Knot endpoint: \(knot)")
    }
    let authority =
      if let port = url.port {
        "\(host):\(port)".replacingOccurrences(of: ":", with: "%3A")
      } else {
        host
      }
    return "did:web:\(authority)"
  }
}

private enum PullRequestMergeServiceError: Error, Sendable {
  case invalidRepositoryURI
  case nonUTF8Patch
}
