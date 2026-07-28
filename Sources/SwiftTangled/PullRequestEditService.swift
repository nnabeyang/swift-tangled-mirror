public struct PullRequestEditContext: Sendable {
  public let pullRequest: TangledRecord<PullRequest>

  let snapshot: PullRequestRecordSnapshot
}

public struct PullRequestEditService: Sendable {
  private let dependencies: PullRequestEditDependencies

  public init(pdsRecordClient: PDSRecordClient = PDSRecordClient()) {
    dependencies = PullRequestEditDependencies(
      snapshot: { try await pdsRecordClient.pullRequestSnapshot(uri: $0) },
      update: { try await $3.updatePullRequest(current: $0, title: $1, body: $2) }
    )
  }

  init(dependencies: PullRequestEditDependencies) {
    self.dependencies = dependencies
  }

  public func prepare(pullRequestURI: String) async throws -> PullRequestEditContext {
    let snapshot = try await dependencies.snapshot(pullRequestURI)
    guard snapshot.record.uri == pullRequestURI else {
      throw TangledError.upstreamFailed(
        "PDS returned a different pull request record: \(snapshot.record.uri)"
      )
    }
    return PullRequestEditContext(
      pullRequest: snapshot.record,
      snapshot: snapshot
    )
  }

  public func edit(
    _ context: PullRequestEditContext,
    title: String,
    body: String?,
    pdsClient: PDSClient
  ) async throws -> TangledRecord<PullRequest> {
    try await dependencies.update(context.snapshot, title, body, pdsClient)
  }
}

struct PullRequestEditDependencies: Sendable {
  let snapshot: @Sendable (String) async throws -> PullRequestRecordSnapshot
  let update:
    @Sendable (PullRequestRecordSnapshot, String, String?, PDSClient) async throws ->
      TangledRecord<PullRequest>
}
