import Foundation
import SwiftAtproto

public struct RepositoryCollaborator: Codable, Equatable, Hashable, Sendable {
  public let subjectDID: String
  public let addedByDID: String
  public let createdAt: FormatString<Date>
  public let recordURI: String?
  public let recordCID: String?

  public init(
    subjectDID: String,
    addedByDID: String,
    createdAt: FormatString<Date>,
    recordURI: String? = nil,
    recordCID: String? = nil
  ) {
    self.subjectDID = subjectDID
    self.addedByDID = addedByDID
    self.createdAt = createdAt
    self.recordURI = recordURI
    self.recordCID = recordCID
  }
}

public struct RepositoryCollaboratorTarget: Codable, Equatable, Sendable {
  public let repositoryURI: String
  public let repositoryDID: String
  public let repositoryName: String
  public let ownerDID: String
  public let knot: String
  public let collaboratorDID: String

  public init(
    repositoryURI: String,
    repositoryDID: String,
    repositoryName: String,
    ownerDID: String,
    knot: String,
    collaboratorDID: String
  ) {
    self.repositoryURI = repositoryURI
    self.repositoryDID = repositoryDID
    self.repositoryName = repositoryName
    self.ownerDID = ownerDID
    self.knot = knot
    self.collaboratorDID = collaboratorDID
  }
}

public enum RepositoryCollaboratorMutationOutcome: String, Codable, Equatable, Sendable {
  case added
  case alreadyPresent = "already_present"
  case removed
  case notPresent = "not_present"
  case cancelled
  case outcomeUnknown = "outcome_unknown"
}

public struct RepositoryCollaboratorMutationResult: Codable, Equatable, Sendable {
  public let outcome: RepositoryCollaboratorMutationOutcome
  public let target: RepositoryCollaboratorTarget
  public let error: String?

  public init(
    outcome: RepositoryCollaboratorMutationOutcome,
    target: RepositoryCollaboratorTarget,
    error: String? = nil
  ) {
    self.outcome = outcome
    self.target = target
    self.error = error
  }
}

public struct RepositoryCollaboratorRemovalPlan: Equatable, Sendable {
  public let target: RepositoryCollaboratorTarget
  public let isPresent: Bool

  public init(target: RepositoryCollaboratorTarget, isPresent: Bool) {
    self.target = target
    self.isPresent = isPresent
  }
}
