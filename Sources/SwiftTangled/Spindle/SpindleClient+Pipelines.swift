import Foundation
import SwiftAtproto
import TangledLexicons

extension SpindleClient {
  public func pipelines(
    repositoryDID: String,
    commits: [String] = [],
    triggerKinds: [PipelineTriggerKind] = [],
    cursor: String? = nil,
    limit: Int? = nil
  ) async throws -> PipelinePage {
    try requireNonempty(repositoryDID, name: "repository DID")
    guard commits.allSatisfy({ !$0.isEmpty }) else {
      throw TangledError.invalidRequest("commits must not contain an empty value")
    }
    if let limit, !(1 ... 250).contains(limit) {
      throw TangledError.invalidRequest("limit must be between 1 and 250")
    }

    let generatedKinds = try triggerKinds.map { kind in
      guard
        let generated = Sh.Tangled.CiQueryPipelines_Kinds_Elem(rawValue: kind.rawValue)
      else {
        throw TangledError.invalidRequest(
          "trigger kind must be push, pull_request, or manual"
        )
      }
      return generated
    }

    let response = try await generatedQuery {
      try await CiQueryPipelines(
        commits: commits.isEmpty ? nil : commits,
        cursor: cursor,
        kinds: generatedKinds.isEmpty ? nil : generatedKinds,
        limit: limit,
        repo: FormatString<DID>(rawValue: repositoryDID)
      )
    }
    return try PipelinePage(
      pipelines: response.pipelines.map { try pipeline(from: $0) },
      cursor: response.cursor,
      total: response.total
    )
  }

  public func pipeline(id: String) async throws -> Pipeline {
    try requireNonempty(id, name: "pipeline ID")
    guard (try? TID(string: id)) != nil else {
      throw TangledError.invalidRequest("pipeline ID must be a valid TID")
    }

    let response = try await generatedQuery {
      try await CiGetPipeline(pipeline: FormatString<TID>(rawValue: id))
    }
    return try pipeline(from: response)
  }
}

extension SpindleClient {
  private func requireNonempty(_ value: String, name: String) throws {
    guard !value.isEmpty else {
      throw TangledError.invalidRequest("\(name) must not be empty")
    }
  }

  private func generatedQuery<Response: Sendable>(
    _ operation: () async throws -> Response
  ) async throws -> Response {
    do {
      return try await operation()
    } catch let error as DecodingError {
      throw TangledError.decoding(error)
    }
  }

  private func pipeline(from value: Sh.Tangled.CiPipeline) throws -> Pipeline {
    Pipeline(
      id: value.id,
      repositoryDID: value.repo?.rawValue,
      sourceRepositoryDID: value.sourceRepo?.rawValue,
      commit: value.commit,
      createdAt: value.createdAt,
      trigger: try trigger(from: value.trigger),
      workflows: value.workflows.map {
        PipelineWorkflow(
          id: $0.id,
          name: $0.name,
          status: PipelineWorkflowStatus(rawValue: $0.status.rawValue),
          startedAt: $0.startedAt,
          finishedAt: $0.finishedAt,
          error: $0.error
        )
      }
    )
  }

  private func trigger(from value: Sh.Tangled.CiPipeline_Trigger) throws -> PipelineTrigger {
    switch value {
    case .ciTriggerPush(let trigger):
      return .push(
        PipelinePushTrigger(
          ref: trigger.ref,
          newSHA: trigger.newSha,
          oldSHA: trigger.oldSha
        )
      )
    case .ciTriggerPullRequest(let trigger):
      return .pullRequest(
        PipelinePullRequestTrigger(
          targetBranch: trigger.targetBranch,
          sourceSHA: trigger.sourceSha,
          sourceRepositoryDID: trigger.sourceRepo?.rawValue,
          sourceBranch: trigger.sourceBranch,
          pullRequestURI: trigger.pull?.rawValue
        )
      )
    case .ciTriggerManual(let trigger):
      return .manual(
        PipelineManualTrigger(
          sha: trigger.sha,
          ref: trigger.ref,
          sourceRepositoryDID: trigger.sourceRepo?.rawValue,
          inputs: trigger.inputs?.map { PipelineManualInput(key: $0.key, value: $0.value) }
            ?? []
        )
      )
    case ._other(let trigger):
      let data = try JSONEncoder().encode(trigger)
      var fields = try JSONDecoder().decode([String: JSONValue].self, from: data)
      fields.removeValue(forKey: "$type")
      return .unknown(type: trigger.type, fields: fields)
    }
  }
}
