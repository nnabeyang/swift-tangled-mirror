import Foundation

public struct PipelineRetryService: Sendable {
  private let dependencies: PipelineRetryDependencies

  public init(spindleClient: SpindleClient, pdsClient: PDSClient) {
    self.init(
      dependencies: PipelineRetryDependencies(
        pipeline: { try await spindleClient.pipeline(id: $0) },
        serviceAuthToken: {
          try await pdsClient.serviceAuthToken(audience: $0, lxm: $1)
        },
        trigger: {
          try await spindleClient.triggerPipeline(
            repositoryDID: $0,
            trigger: $1,
            workflows: $2,
            token: $3
          )
        },
        serviceAudience: { try spindleServiceAudience(spindleClient.baseURL) }
      )
    )
  }

  init(dependencies: PipelineRetryDependencies) {
    self.dependencies = dependencies
  }

  public func retry(
    pipelineID: String,
    repositoryDID: String,
    workflow: String? = nil
  ) async throws -> String {
    let pipeline = try await dependencies.pipeline(pipelineID)
    let commit = try requiredCommit(pipeline.commit)
    let workflows = try selectedWorkflows(workflow, from: pipeline.workflows)
    let trigger = try retryTrigger(pipeline.trigger, pipeline: pipeline, commit: commit)
    let audience = try dependencies.serviceAudience()
    let token = try await dependencies.serviceAuthToken(audience, pipelineTriggerMethod)
    return try await dependencies.trigger(repositoryDID, trigger, workflows, token)
  }
}

struct PipelineRetryDependencies: Sendable {
  let pipeline: @Sendable (String) async throws -> Pipeline
  let serviceAuthToken: @Sendable (String, String) async throws -> String
  let trigger: @Sendable (String, PipelineTrigger, [String], String) async throws -> String
  let serviceAudience: @Sendable () throws -> String
}

extension PipelineRetryService {
  private func requiredCommit(_ commit: String) throws -> String {
    guard commit.utf8.count == 40, commit.allSatisfy(\.isHexDigit) else {
      throw TangledError.invalidRequest(
        "original pipeline does not expose a 40-character commit hash"
      )
    }
    return commit
  }

  private func selectedWorkflows(
    _ requested: String?,
    from workflows: [PipelineWorkflow]
  ) throws -> [String] {
    guard !workflows.isEmpty else {
      throw TangledError.invalidRequest("original pipeline does not contain any workflows")
    }
    guard let requested else {
      return workflows.map(\.name)
    }
    let trimmedRequested = requested.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedRequested.isEmpty else {
      throw TangledError.invalidRequest("workflow name must not be empty")
    }
    guard workflows.contains(where: { $0.name == trimmedRequested }) else {
      throw TangledError.invalidRequest(
        "workflow is not present in the original pipeline: \(trimmedRequested)"
      )
    }
    return [trimmedRequested]
  }

  private func retryTrigger(
    _ trigger: PipelineTrigger,
    pipeline: Pipeline,
    commit: String
  ) throws -> PipelineTrigger {
    switch trigger {
    case .pullRequest(let value):
      let sourceSHA = value.sourceSHA.isEmpty ? commit : value.sourceSHA
      _ = try requiredCommit(sourceSHA)
      guard !value.targetBranch.isEmpty else {
        throw TangledError.invalidRequest(
          "original pull-request trigger does not expose a target branch"
        )
      }
      return .pullRequest(
        PipelinePullRequestTrigger(
          targetBranch: value.targetBranch,
          sourceSHA: sourceSHA,
          sourceRepositoryDID: value.sourceRepositoryDID
            ?? pipeline.sourceRepositoryDID
            ?? pipeline.repositoryDID,
          sourceBranch: value.sourceBranch,
          pullRequestURI: value.pullRequestURI
        )
      )
    case .manual(let value):
      let sha = value.sha.isEmpty ? commit : value.sha
      _ = try requiredCommit(sha)
      return .manual(
        PipelineManualTrigger(
          sha: sha,
          ref: value.ref,
          sourceRepositoryDID: value.sourceRepositoryDID
            ?? pipeline.sourceRepositoryDID
            ?? pipeline.repositoryDID,
          inputs: value.inputs
        )
      )
    case .push, .unknown:
      return .manual(
        PipelineManualTrigger(
          sha: commit,
          sourceRepositoryDID: pipeline.sourceRepositoryDID ?? pipeline.repositoryDID
        )
      )
    }
  }
}
