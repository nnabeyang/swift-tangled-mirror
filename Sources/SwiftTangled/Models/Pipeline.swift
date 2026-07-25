import Foundation
import SwiftAtproto

public struct PipelineTriggerKind: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let push = PipelineTriggerKind(rawValue: "push")
  public static let pullRequest = PipelineTriggerKind(rawValue: "pull_request")
  public static let manual = PipelineTriggerKind(rawValue: "manual")

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try String(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try rawValue.encode(to: encoder)
  }
}

public struct PipelineWorkflowStatus: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let pending = PipelineWorkflowStatus(rawValue: "pending")
  public static let running = PipelineWorkflowStatus(rawValue: "running")
  public static let failed = PipelineWorkflowStatus(rawValue: "failed")
  public static let timeout = PipelineWorkflowStatus(rawValue: "timeout")
  public static let cancelled = PipelineWorkflowStatus(rawValue: "cancelled")
  public static let success = PipelineWorkflowStatus(rawValue: "success")

  public var isTerminal: Bool {
    self == .failed || self == .timeout || self == .cancelled || self == .success
  }

  public var isSuccessful: Bool {
    self == .success
  }

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try String(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try rawValue.encode(to: encoder)
  }
}

public struct PipelineWorkflow: Codable, Equatable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let status: PipelineWorkflowStatus
  public let startedAt: FormatString<Date>?
  public let finishedAt: FormatString<Date>?
  public let error: String?

  public init(
    id: String,
    name: String,
    status: PipelineWorkflowStatus,
    startedAt: FormatString<Date>? = nil,
    finishedAt: FormatString<Date>? = nil,
    error: String? = nil
  ) {
    self.id = id
    self.name = name
    self.status = status
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.error = error
  }
}

public struct PipelinePushTrigger: Codable, Equatable, Hashable, Sendable {
  public let ref: String
  public let newSHA: String
  public let oldSHA: String

  public init(ref: String, newSHA: String, oldSHA: String) {
    self.ref = ref
    self.newSHA = newSHA
    self.oldSHA = oldSHA
  }

  private enum CodingKeys: String, CodingKey {
    case ref
    case newSHA = "newSha"
    case oldSHA = "oldSha"
  }
}

public struct PipelinePullRequestTrigger: Codable, Equatable, Hashable, Sendable {
  public let targetBranch: String
  public let sourceSHA: String
  public let sourceRepositoryDID: String?
  public let sourceBranch: String?
  public let pullRequestURI: String?

  public init(
    targetBranch: String,
    sourceSHA: String,
    sourceRepositoryDID: String? = nil,
    sourceBranch: String? = nil,
    pullRequestURI: String? = nil
  ) {
    self.targetBranch = targetBranch
    self.sourceSHA = sourceSHA
    self.sourceRepositoryDID = sourceRepositoryDID
    self.sourceBranch = sourceBranch
    self.pullRequestURI = pullRequestURI
  }

  private enum CodingKeys: String, CodingKey {
    case targetBranch
    case sourceSHA = "sourceSha"
    case sourceRepositoryDID = "sourceRepo"
    case sourceBranch
    case pullRequestURI = "pull"
  }
}

public struct PipelineManualInput: Codable, Equatable, Hashable, Sendable {
  public let key: String
  public let value: String

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }
}

public struct PipelineManualTrigger: Codable, Equatable, Hashable, Sendable {
  public let sha: String
  public let ref: String?
  public let sourceRepositoryDID: String?
  public let inputs: [PipelineManualInput]

  public init(
    sha: String,
    ref: String? = nil,
    sourceRepositoryDID: String? = nil,
    inputs: [PipelineManualInput] = []
  ) {
    self.sha = sha
    self.ref = ref
    self.sourceRepositoryDID = sourceRepositoryDID
    self.inputs = inputs
  }

  private enum CodingKeys: String, CodingKey {
    case sha
    case ref
    case sourceRepositoryDID = "sourceRepo"
    case inputs
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      sha: try container.decode(String.self, forKey: .sha),
      ref: try container.decodeIfPresent(String.self, forKey: .ref),
      sourceRepositoryDID: try container.decodeIfPresent(
        String.self,
        forKey: .sourceRepositoryDID
      ),
      inputs: try container.decodeIfPresent([PipelineManualInput].self, forKey: .inputs) ?? []
    )
  }
}

public enum PipelineTrigger: Codable, Equatable, Hashable, Sendable {
  case push(PipelinePushTrigger)
  case pullRequest(PipelinePullRequestTrigger)
  case manual(PipelineManualTrigger)
  case unknown(type: String, fields: [String: JSONValue])

  private enum CodingKeys: String, CodingKey {
    case type = "$type"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "sh.tangled.ci.trigger#push":
      self = try .push(PipelinePushTrigger(from: decoder))
    case "sh.tangled.ci.trigger#pullRequest":
      self = try .pullRequest(PipelinePullRequestTrigger(from: decoder))
    case "sh.tangled.ci.trigger#manual":
      self = try .manual(PipelineManualTrigger(from: decoder))
    default:
      var fields = try [String: JSONValue](from: decoder)
      fields.removeValue(forKey: "$type")
      self = .unknown(type: type, fields: fields)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .push(let value):
      try container.encode("sh.tangled.ci.trigger#push", forKey: .type)
      try value.encode(to: encoder)
    case .pullRequest(let value):
      try container.encode("sh.tangled.ci.trigger#pullRequest", forKey: .type)
      try value.encode(to: encoder)
    case .manual(let value):
      try container.encode("sh.tangled.ci.trigger#manual", forKey: .type)
      try value.encode(to: encoder)
    case .unknown(let type, let fields):
      var values = fields
      values["$type"] = .string(type)
      try values.encode(to: encoder)
    }
  }
}

public struct Pipeline: Codable, Equatable, Hashable, Sendable {
  public let id: String
  public let repositoryDID: String?
  public let sourceRepositoryDID: String?
  public let commit: String
  public let createdAt: FormatString<Date>?
  public let trigger: PipelineTrigger
  public let workflows: [PipelineWorkflow]

  public init(
    id: String,
    repositoryDID: String? = nil,
    sourceRepositoryDID: String? = nil,
    commit: String,
    createdAt: FormatString<Date>? = nil,
    trigger: PipelineTrigger,
    workflows: [PipelineWorkflow]
  ) {
    self.id = id
    self.repositoryDID = repositoryDID
    self.sourceRepositoryDID = sourceRepositoryDID
    self.commit = commit
    self.createdAt = createdAt
    self.trigger = trigger
    self.workflows = workflows
  }

  public var isTerminal: Bool {
    !workflows.isEmpty && workflows.allSatisfy(\.status.isTerminal)
  }

  public var isSuccessful: Bool {
    isTerminal && workflows.allSatisfy(\.status.isSuccessful)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case repositoryDID = "repo"
    case sourceRepositoryDID = "sourceRepo"
    case commit
    case createdAt
    case trigger
    case workflows
  }
}

public struct PipelinePage: Codable, Equatable, Sendable {
  public let pipelines: [Pipeline]
  public let cursor: String?
  public let total: Int

  public init(pipelines: [Pipeline], cursor: String? = nil, total: Int) {
    self.pipelines = pipelines
    self.cursor = cursor
    self.total = total
  }
}
