import Foundation
import SwiftAtproto
import TangledLexicons

public struct RepositoryCreationRequest: Equatable, Sendable {
  public let name: String
  public let knot: String
  public let defaultBranch: String
  public let source: String?
  public let repositoryDID: String?

  public init(
    name: String,
    knot: String,
    defaultBranch: String = "main",
    source: String? = nil,
    repositoryDID: String? = nil
  ) {
    self.name = name
    self.knot = knot
    self.defaultBranch = defaultBranch
    self.source = source
    self.repositoryDID = repositoryDID
  }
}

public struct RepositoryLifecycleTarget: Codable, Equatable, Sendable {
  public let ownerDID: String
  public let name: String
  public let rkey: String
  public let recordURI: String
  public let repositoryDID: String?
  public let knot: String
  public let webURL: String
  public let cloneURL: String?

  public init(
    ownerDID: String,
    name: String,
    rkey: String,
    recordURI: String,
    repositoryDID: String?,
    knot: String,
    webURL: String,
    cloneURL: String?
  ) {
    self.ownerDID = ownerDID
    self.name = name
    self.rkey = rkey
    self.recordURI = recordURI
    self.repositoryDID = repositoryDID
    self.knot = knot
    self.webURL = webURL
    self.cloneURL = cloneURL
  }
}

public enum RepositoryCreationOutcome: String, Codable, Equatable, Sendable {
  case created
  case rolledBack = "rolled_back"
  case knotCreatedRecordFailed = "knot_created_record_failed"
  case outcomeUnknown = "outcome_unknown"
}

public struct RepositoryCreationResult: Codable, Equatable, Sendable {
  public let outcome: RepositoryCreationOutcome
  public let target: RepositoryLifecycleTarget
  public let record: TangledRecord<Repository>?
  public let error: String?
  public let cleanupError: String?

  public init(
    outcome: RepositoryCreationOutcome,
    target: RepositoryLifecycleTarget,
    record: TangledRecord<Repository>? = nil,
    error: String? = nil,
    cleanupError: String? = nil
  ) {
    self.outcome = outcome
    self.target = target
    self.record = record
    self.error = error
    self.cleanupError = cleanupError
  }
}

public struct RepositoryDeletionPlan: Sendable {
  public let target: RepositoryLifecycleTarget
  public let record: TangledRecord<Repository>

  public init(target: RepositoryLifecycleTarget, record: TangledRecord<Repository>) {
    self.target = target
    self.record = record
  }
}

public enum RepositoryDeletionOutcome: String, Codable, Equatable, Sendable {
  case deleted
  case cancelled
  case recordDeletedKnotFailed = "record_deleted_knot_failed"
  case outcomeUnknown = "outcome_unknown"
}

public struct RepositoryDeletionResult: Codable, Equatable, Sendable {
  public let outcome: RepositoryDeletionOutcome
  public let target: RepositoryLifecycleTarget
  public let error: String?

  public init(
    outcome: RepositoryDeletionOutcome,
    target: RepositoryLifecycleTarget,
    error: String? = nil
  ) {
    self.outcome = outcome
    self.target = target
    self.error = error
  }
}

public enum RepositoryLifecycleError: Error, Equatable, Sendable {
  case missingRepositoryDID
}

public struct RepositoryLifecycleService: Sendable {
  private let dependencies: RepositoryLifecycleDependencies

  public init(
    repositoryLocator: RepositoryLocator = RepositoryLocator(),
    pdsRecordClient: PDSRecordClient = PDSRecordClient(),
    knotClient: KnotClient = KnotClient()
  ) {
    dependencies = RepositoryLifecycleDependencies(
      repository: { try await repositoryLocator.resolve($0) },
      record: { try await pdsRecordClient.repository(uri: $0) },
      createOnKnot: { try await knotClient.createRepository(knot: $0, token: $1, rkey: $2, name: $3, defaultBranch: $4, source: $5, repositoryDID: $6) },
      deleteOnKnot: { try await knotClient.deleteRepository(knot: $0, token: $1, repositoryDID: $2, ownerDID: $3, name: $4, rkey: $5) }
    )
  }

  init(dependencies: RepositoryLifecycleDependencies) {
    self.dependencies = dependencies
  }

  public func create(
    _ request: RepositoryCreationRequest,
    pdsClient: PDSClient
  ) async throws -> RepositoryCreationResult {
    let prepared = try prepare(request, ownerDID: pdsClient.repoDID)
    try pdsClient.requireRepositoryRecordCreateScope()
    try pdsClient.requireRepositoryRecordDeleteScope()
    do {
      _ = try await dependencies.record(prepared.target.recordURI)
      throw TangledError.conflict("repository record already exists: \(prepared.target.recordURI)")
    } catch TangledError.notFound {
      // Expected.
    }
    let audience = try knotServiceAudience(prepared.target.knot)
    let createToken = try await pdsClient.serviceAuthToken(
      audience: audience,
      lxm: Sh.Tangled.RepoCreate.id
    )
    let deleteToken = try await pdsClient.serviceAuthToken(
      audience: audience,
      lxm: Sh.Tangled.RepoDelete.id
    )

    let repositoryDID: String
    do {
      repositoryDID = try await dependencies.createOnKnot(
        prepared.target.knot,
        createToken,
        prepared.target.rkey,
        prepared.target.rkey,
        prepared.defaultBranch,
        prepared.source,
        prepared.requestedRepositoryDID
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard isAmbiguousWriteFailure(error) else { throw error }
      return RepositoryCreationResult(
        outcome: .outcomeUnknown,
        target: prepared.target,
        error: String(describing: error)
      )
    }

    let target = target(prepared.target, repositoryDID: repositoryDID)
    do {
      let record = try await pdsClient.createRepositoryRecord(
        rkey: target.rkey,
        name: target.name,
        knot: target.knot,
        source: prepared.source,
        repositoryDID: repositoryDID
      )
      return RepositoryCreationResult(outcome: .created, target: target, record: record)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let recordError = error
      do {
        let record = try await dependencies.record(target.recordURI)
        if matches(record, target: target) {
          return RepositoryCreationResult(outcome: .created, target: target, record: record)
        }
        return RepositoryCreationResult(
          outcome: .knotCreatedRecordFailed,
          target: target,
          record: record,
          error: String(describing: recordError)
        )
      } catch TangledError.notFound {
        do {
          try await dependencies.deleteOnKnot(
            target.knot,
            deleteToken,
            repositoryDID,
            target.ownerDID,
            target.rkey,
            target.rkey
          )
          return RepositoryCreationResult(
            outcome: .rolledBack,
            target: target,
            error: String(describing: recordError)
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          return RepositoryCreationResult(
            outcome: .knotCreatedRecordFailed,
            target: target,
            error: String(describing: recordError),
            cleanupError: String(describing: error)
          )
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        return RepositoryCreationResult(
          outcome: .outcomeUnknown,
          target: target,
          error: String(describing: recordError),
          cleanupError: "failed to verify the repository record: \(error)"
        )
      }
    }
  }

  public func prepareDeletion(
    repository: String,
    pdsClient: PDSClient
  ) async throws -> RepositoryDeletionPlan {
    let record = try await dependencies.repository(repository)
    guard let uri = FormatString<ATURI>(rawValue: record.uri).typed,
      uri.authority.rawValue == pdsClient.repoDID,
      let rkey = uri.rkey?.rawValue,
      let repositoryDID = record.value.repoDID,
      record.cid != nil
    else {
      throw TangledError.forbidden(
        "only the repository record owner can delete a repository with a CID and repository DID"
      )
    }
    try pdsClient.requireRepositoryRecordDeleteScope()
    let audience = try knotServiceAudience(record.value.knot)
    _ = try await pdsClient.serviceAuthToken(audience: audience, lxm: Sh.Tangled.RepoDelete.id)
    let name = record.value.name ?? rkey
    return RepositoryDeletionPlan(
      target: makeTarget(
        ownerDID: pdsClient.repoDID,
        name: name,
        rkey: rkey,
        knot: record.value.knot,
        repositoryDID: repositoryDID
      ),
      record: record
    )
  }

  public func delete(
    _ plan: RepositoryDeletionPlan,
    pdsClient: PDSClient
  ) async throws -> RepositoryDeletionResult {
    let audience = try knotServiceAudience(plan.target.knot)
    let token = try await pdsClient.serviceAuthToken(
      audience: audience,
      lxm: Sh.Tangled.RepoDelete.id
    )
    do {
      try await pdsClient.deleteRepositoryRecord(plan.record)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let recordError = error
      do {
        let current = try await dependencies.record(plan.target.recordURI)
        guard current.cid != plan.record.cid else { throw recordError }
        throw TangledError.conflict("repository record changed before deletion")
      } catch TangledError.notFound {
        // The write succeeded even though its response was lost.
      } catch is CancellationError {
        throw CancellationError()
      } catch let verificationError where isAmbiguousWriteFailure(verificationError) {
        return RepositoryDeletionResult(
          outcome: .outcomeUnknown,
          target: plan.target,
          error: "\(recordError); failed to verify record deletion: \(verificationError)"
        )
      }
    }
    do {
      try await dependencies.deleteOnKnot(
        plan.target.knot,
        token,
        plan.target.repositoryDID!,
        plan.target.ownerDID,
        plan.target.rkey,
        plan.target.rkey
      )
      return RepositoryDeletionResult(outcome: .deleted, target: plan.target)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return RepositoryDeletionResult(
        outcome: .recordDeletedKnotFailed,
        target: plan.target,
        error: String(describing: error)
      )
    }
  }
}

struct RepositoryLifecycleDependencies: Sendable {
  let repository: @Sendable (String) async throws -> TangledRecord<Repository>
  let record: @Sendable (String) async throws -> TangledRecord<Repository>
  let createOnKnot: @Sendable (String, String, String, String, String, String?, String?) async throws -> String
  let deleteOnKnot: @Sendable (String, String, String, String, String, String) async throws -> Void
}

extension RepositoryLifecycleService {
  private struct PreparedCreation {
    let target: RepositoryLifecycleTarget
    let defaultBranch: String
    let source: String?
    let requestedRepositoryDID: String?
  }

  private func prepare(
    _ request: RepositoryCreationRequest,
    ownerDID: String
  ) throws -> PreparedCreation {
    let name = try normalizedRepositoryName(request.name)
    let rkey = name.lowercased()
    do {
      _ = try RecordKey(string: rkey)
    } catch {
      throw TangledError.invalidRequest("invalid repository record key: \(rkey)")
    }
    let defaultBranch = request.defaultBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !defaultBranch.isEmpty else {
      throw TangledError.invalidRequest("default branch must not be empty")
    }
    _ = try knotServiceAudience(request.knot)
    let source = try request.source.map(validatedSource)
    let repositoryDID = try request.repositoryDID.map(validatedCustomRepositoryDID)
    return PreparedCreation(
      target: makeTarget(
        ownerDID: ownerDID,
        name: name,
        rkey: rkey,
        knot: request.knot,
        repositoryDID: nil
      ),
      defaultBranch: defaultBranch,
      source: source,
      requestedRepositoryDID: repositoryDID
    )
  }

  private func normalizedRepositoryName(_ rawValue: String) throws(TangledError) -> String {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.lowercased().hasSuffix(".git") {
      value.removeLast(4)
    }
    guard !value.isEmpty else {
      throw TangledError.invalidRequest("repository name must not be empty")
    }
    guard value.count <= 100 else {
      throw TangledError.invalidRequest("repository name must be 100 characters or fewer")
    }
    guard value != ".", value != "..", !value.hasPrefix("."), !value.hasSuffix("."),
      !value.contains(".."), !value.contains("/"), !value.contains("\\")
    else {
      throw TangledError.invalidRequest("repository name contains an invalid path sequence")
    }
    guard value.lowercased() != "self" else {
      throw TangledError.invalidRequest("repository name \"self\" is reserved")
    }
    guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }) else {
      throw TangledError.invalidRequest(
        "repository name can only contain ASCII letters, numbers, periods, hyphens, and underscores"
      )
    }
    return value
  }

  private func validatedSource(_ rawValue: String) throws(TangledError) -> String {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: value), components.scheme != nil,
      components.host != nil
    else {
      throw TangledError.invalidRequest("source must be an absolute Git clone URL")
    }
    do {
      _ = try URI(string: value)
    } catch {
      throw TangledError.invalidRequest("source must be an absolute Git clone URL")
    }
    return value
  }

  private func validatedCustomRepositoryDID(_ rawValue: String) throws(TangledError) -> String {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("did:web:") else {
      throw TangledError.invalidRequest("custom repository DID must be a did:web DID")
    }
    do {
      _ = try DID(string: value)
    } catch {
      throw TangledError.invalidRequest("custom repository DID must be a did:web DID")
    }
    return value
  }

  private func makeTarget(
    ownerDID: String,
    name: String,
    rkey: String,
    knot: String,
    repositoryDID: String?
  ) -> RepositoryLifecycleTarget {
    let recordURI = "at://\(ownerDID)/\(Sh.Tangled.Repo.nsId)/\(rkey)"
    let webURL = "https://tangled.org/\(ownerDID)/\(rkey)"
    let resolvedCloneURL: String?
    if let repositoryDID {
      resolvedCloneURL = cloneURL(knot: knot, repositoryDID: repositoryDID)
    } else {
      resolvedCloneURL = nil
    }
    return RepositoryLifecycleTarget(
      ownerDID: ownerDID,
      name: name,
      rkey: rkey,
      recordURI: recordURI,
      repositoryDID: repositoryDID,
      knot: knot,
      webURL: webURL,
      cloneURL: resolvedCloneURL
    )
  }

  private func target(
    _ target: RepositoryLifecycleTarget,
    repositoryDID: String
  ) -> RepositoryLifecycleTarget {
    makeTarget(
      ownerDID: target.ownerDID,
      name: target.name,
      rkey: target.rkey,
      knot: target.knot,
      repositoryDID: repositoryDID
    )
  }

  private func cloneURL(knot: String, repositoryDID: String) -> String? {
    let rawValue = knot.contains("://") ? knot : "https://\(knot)"
    return URL(string: rawValue)?.appendingPathComponent(repositoryDID).absoluteString
  }

  private func matches(
    _ record: TangledRecord<Repository>,
    target: RepositoryLifecycleTarget
  ) -> Bool {
    record.uri == target.recordURI
      && record.value.repoDID == target.repositoryDID
      && record.value.knot == target.knot
      && record.value.name == target.name
  }
}

private func isAmbiguousWriteFailure(_ error: any Error) -> Bool {
  guard let error = error as? TangledError else { return false }
  return switch error {
  case .network, .transport, .decoding, .rateLimited, .serviceUnavailable:
    true
  case .serverStatus(let status, _):
    status >= 500
  default:
    false
  }
}
