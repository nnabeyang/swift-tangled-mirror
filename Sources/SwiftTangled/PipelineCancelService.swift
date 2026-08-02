import Foundation

public struct PipelineCancellation: Codable, Equatable, Sendable {
  public let pipeline: String
  public let workflows: [String]

  public init(pipeline: String, workflows: [String]) {
    self.pipeline = pipeline
    self.workflows = workflows
  }
}

public struct PipelineCancelService: Sendable {
  private let dependencies: PipelineCancelDependencies

  public init(spindleClient: SpindleClient, pdsClient: PDSClient) {
    self.init(
      dependencies: PipelineCancelDependencies(
        pipeline: { try await spindleClient.pipeline(id: $0) },
        serviceAuthToken: {
          try await pdsClient.serviceAuthToken(audience: $0, lxm: $1)
        },
        cancel: {
          try await spindleClient.cancelPipeline(
            repositoryDID: $0,
            pipelineID: $1,
            workflows: $2,
            token: $3
          )
        },
        serviceAudience: { try spindleServiceAudience(spindleClient.baseURL) }
      )
    )
  }

  init(dependencies: PipelineCancelDependencies) {
    self.dependencies = dependencies
  }

  public func cancel(
    pipelineID: String,
    repositoryDID: String,
    workflows: [String] = []
  ) async throws -> PipelineCancellation {
    let requested = try normalizedWorkflows(workflows)
    let pipeline = try await dependencies.pipeline(pipelineID)
    let selected = try selectedWorkflows(requested, from: pipeline)
    let audience = try dependencies.serviceAudience()
    let token = try await dependencies.serviceAuthToken(audience, pipelineCancelMethod)
    try await dependencies.cancel(repositoryDID, pipelineID, selected, token)
    return PipelineCancellation(pipeline: pipelineID, workflows: selected)
  }
}

struct PipelineCancelDependencies: Sendable {
  let pipeline: @Sendable (String) async throws -> Pipeline
  let serviceAuthToken: @Sendable (String, String) async throws -> String
  let cancel: @Sendable (String, String, [String], String) async throws -> Void
  let serviceAudience: @Sendable () throws -> String
}

extension PipelineCancelService {
  private func normalizedWorkflows(_ workflows: [String]) throws(TangledError) -> [String] {
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

  private func selectedWorkflows(
    _ requested: [String],
    from pipeline: Pipeline
  ) throws(TangledError) -> [String] {
    guard !pipeline.workflows.isEmpty else {
      throw TangledError.invalidRequest("pipeline does not contain any workflows")
    }

    if requested.isEmpty {
      let active = pipeline.workflows.filter { !$0.status.isTerminal }.map(\.name)
      guard !active.isEmpty else {
        throw TangledError.invalidRequest("pipeline is already finished")
      }
      return active
    }

    let workflowsByName = Dictionary(
      pipeline.workflows.map { ($0.name, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    for name in requested where workflowsByName[name] == nil {
      throw TangledError.invalidRequest(
        "workflow is not present in the pipeline: \(name)"
      )
    }
    let active = requested.filter { workflowsByName[$0]?.status.isTerminal == false }
    guard !active.isEmpty else {
      throw TangledError.invalidRequest("selected workflows are already finished")
    }
    return active
  }
}
