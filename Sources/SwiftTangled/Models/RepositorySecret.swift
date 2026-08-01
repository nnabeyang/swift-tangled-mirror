import Foundation
import SwiftAtproto

public struct RepositorySecret: Codable, Equatable, Hashable, Sendable {
  public let repositoryURI: String
  public let key: String
  public let createdAt: FormatString<Date>
  public let createdByDID: String

  public init(
    repositoryURI: String,
    key: String,
    createdAt: FormatString<Date>,
    createdByDID: String
  ) {
    self.repositoryURI = repositoryURI
    self.key = key
    self.createdAt = createdAt
    self.createdByDID = createdByDID
  }
}

public struct RepositorySecretList: Codable, Equatable, Sendable {
  public let repositoryURI: String
  public let repositoryName: String
  public let spindle: String
  public let secrets: [RepositorySecret]

  public init(
    repositoryURI: String,
    repositoryName: String,
    spindle: String,
    secrets: [RepositorySecret]
  ) {
    self.repositoryURI = repositoryURI
    self.repositoryName = repositoryName
    self.spindle = spindle
    self.secrets = secrets
  }
}

public struct RepositorySecretTarget: Codable, Equatable, Sendable {
  public let repositoryURI: String
  public let repositoryName: String
  public let spindle: String
  public let key: String

  public init(
    repositoryURI: String,
    repositoryName: String,
    spindle: String,
    key: String
  ) {
    self.repositoryURI = repositoryURI
    self.repositoryName = repositoryName
    self.spindle = spindle
    self.key = key
  }
}

public enum RepositorySecretMutationOutcome: String, Codable, Equatable, Sendable {
  case added
  case alreadyPresent = "already_present"
  case removed
  case notPresent = "not_present"
  case cancelled
  case outcomeUnknown = "outcome_unknown"
}

public struct RepositorySecretMutationResult: Codable, Equatable, Sendable {
  public let outcome: RepositorySecretMutationOutcome
  public let target: RepositorySecretTarget

  public init(outcome: RepositorySecretMutationOutcome, target: RepositorySecretTarget) {
    self.outcome = outcome
    self.target = target
  }
}

public struct RepositorySecretAdditionPlan: Equatable, Sendable {
  public let target: RepositorySecretTarget
  public let isPresent: Bool

  public init(target: RepositorySecretTarget, isPresent: Bool) {
    self.target = target
    self.isPresent = isPresent
  }
}

public struct RepositorySecretRemovalPlan: Equatable, Sendable {
  public let target: RepositorySecretTarget
  public let isPresent: Bool

  public init(target: RepositorySecretTarget, isPresent: Bool) {
    self.target = target
    self.isPresent = isPresent
  }
}
