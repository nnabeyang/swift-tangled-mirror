import Foundation

public struct PipelineRunService: Sendable {
  private let dependencies: PipelineRunDependencies

  public init(spindleClient: SpindleClient, pdsClient: PDSClient) {
    self.init(
      dependencies: PipelineRunDependencies(
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

  init(dependencies: PipelineRunDependencies) {
    self.dependencies = dependencies
  }

  public func run(
    repositoryDID: String,
    commit: String,
    ref: String? = nil,
    workflows: [String] = [],
    inputs: [PipelineManualInput] = []
  ) async throws -> String {
    let commit = try validatedCommit(commit)
    let ref = try normalizedRef(ref)
    let workflows = try normalizedWorkflows(workflows)
    let inputs = try normalizedInputs(inputs)
    let trigger = PipelineTrigger.manual(
      PipelineManualTrigger(sha: commit, ref: ref, inputs: inputs)
    )
    let audience = try dependencies.serviceAudience()
    let token = try await dependencies.serviceAuthToken(audience, pipelineTriggerMethod)
    return try await dependencies.trigger(
      repositoryDID,
      trigger,
      workflows.isEmpty ? nil : workflows,
      token
    )
  }
}

struct PipelineRunDependencies: Sendable {
  let serviceAuthToken: @Sendable (String, String) async throws -> String
  let trigger: @Sendable (String, PipelineTrigger, [String]?, String) async throws -> String
  let serviceAudience: @Sendable () throws -> String
}

extension PipelineRunService {
  private func validatedCommit(_ commit: String) throws -> String {
    guard commit.utf8.count == 40, commit.allSatisfy(\.isHexDigit) else {
      throw TangledError.invalidRequest("commit must be a 40-character hexadecimal SHA")
    }
    return commit
  }

  private func normalizedRef(_ ref: String?) throws -> String? {
    guard let ref else { return nil }
    let normalized = ref.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      throw TangledError.invalidRequest("ref must not be empty")
    }
    return normalized
  }

  private func normalizedWorkflows(_ workflows: [String]) throws -> [String] {
    var seen = Set<String>()
    var normalized: [String] = []
    for workflow in workflows {
      let name = workflow.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        throw TangledError.invalidRequest("workflow name must not be empty")
      }
      if seen.insert(name).inserted {
        normalized.append(name)
      }
    }
    return normalized
  }

  private func normalizedInputs(
    _ inputs: [PipelineManualInput]
  ) throws -> [PipelineManualInput] {
    var seen = Set<String>()
    return try inputs.map { input in
      let key = input.key.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else {
        throw TangledError.invalidRequest("input key must not be empty")
      }
      guard seen.insert(key.uppercased()).inserted else {
        throw TangledError.invalidRequest("duplicate input key: \(key)")
      }
      return PipelineManualInput(key: key, value: input.value)
    }
  }
}
