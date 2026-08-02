public struct RepositoryDefaultBranchTarget: Codable, Equatable, Sendable {
  public let uri: String
  public let did: String
  public let name: String
  public let knot: String

  public init(uri: String, did: String, name: String, knot: String) {
    self.uri = uri
    self.did = did
    self.name = name
    self.knot = knot
  }
}

public enum RepositoryDefaultBranchChangeOutcome: String, Codable, Equatable, Sendable {
  case changed
  case unchanged
  case outcomeUnknown = "outcome_unknown"
}

public struct RepositoryDefaultBranchChangeResult: Codable, Equatable, Sendable {
  public let outcome: RepositoryDefaultBranchChangeOutcome
  public let repository: RepositoryDefaultBranchTarget
  public let oldBranch: String
  public let newBranch: String
  public let error: String?

  public init(
    outcome: RepositoryDefaultBranchChangeOutcome,
    repository: RepositoryDefaultBranchTarget,
    oldBranch: String,
    newBranch: String,
    error: String? = nil
  ) {
    self.outcome = outcome
    self.repository = repository
    self.oldBranch = oldBranch
    self.newBranch = newBranch
    self.error = error
  }
}

public struct RepositoryDefaultBranchChangePlan: Equatable, Sendable {
  public let repository: RepositoryDefaultBranchTarget
  public let oldBranch: String
  public let newBranch: String

  public init(
    repository: RepositoryDefaultBranchTarget,
    oldBranch: String,
    newBranch: String
  ) {
    self.repository = repository
    self.oldBranch = oldBranch
    self.newBranch = newBranch
  }

  public var requiresChange: Bool { oldBranch != newBranch }
}
