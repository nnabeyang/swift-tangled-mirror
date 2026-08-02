import Foundation
import SwiftAtproto
import TangledLexicons

public struct RepositoryDefaultBranchService: Sendable {
  private let dependencies: RepositoryDefaultBranchDependencies

  public init(
    repositoryLocator: RepositoryLocator = RepositoryLocator(),
    knotClient: KnotClient = KnotClient()
  ) {
    dependencies = RepositoryDefaultBranchDependencies(
      repository: { try await repositoryLocator.resolve($0) },
      defaultBranch: { try await knotClient.defaultBranch(knot: $0, repositoryDID: $1) },
      branch: { try await knotClient.branch(knot: $0, repositoryDID: $1, name: $2) },
      setDefaultBranch: {
        try await knotClient.setDefaultBranch(
          knot: $0,
          token: $1,
          repositoryURI: $2,
          branch: $3
        )
      }
    )
  }

  init(dependencies: RepositoryDefaultBranchDependencies) {
    self.dependencies = dependencies
  }

  public func view(repository: String) async throws -> RepositoryView {
    let record = try await dependencies.repository(repository)
    guard let repositoryDID = record.value.repoDID else {
      return RepositoryView(record: record, defaultBranch: nil)
    }
    do {
      _ = try DID(string: repositoryDID)
    } catch {
      throw TangledError.upstreamFailed("repository record has an invalid repository DID")
    }
    return RepositoryView(
      record: record,
      defaultBranch: try await dependencies.defaultBranch(
        record.value.knot,
        repositoryDID
      )
    )
  }

  public func prepareChange(
    repository: String,
    branch rawBranch: String
  ) async throws -> RepositoryDefaultBranchChangePlan {
    let branch = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branch.isEmpty else {
      throw TangledError.invalidRequest("branch must not be empty")
    }
    let resolved = try await resolvedRepository(repository)
    let current: GitDefaultBranch
    do {
      current = try await dependencies.defaultBranch(
        resolved.target.knot,
        resolved.target.did
      )
    } catch Sh.Tangled.RepoGetDefaultBranch.Error.invalidrequest {
      throw TangledError.invalidRequest("repository is not initialized with a default branch")
    }
    let plan = RepositoryDefaultBranchChangePlan(
      repository: resolved.target,
      oldBranch: current.name,
      newBranch: branch
    )
    guard plan.requiresChange else { return plan }
    do {
      _ = try await dependencies.branch(
        resolved.target.knot,
        resolved.target.did,
        branch
      )
    } catch Sh.Tangled.RepoBranch.Error.branchnotfound {
      throw TangledError.notFound("branch does not exist on the Knot: \(branch)")
    }
    return plan
  }

  public func change(
    _ plan: RepositoryDefaultBranchChangePlan,
    pdsClient: PDSClient
  ) async throws -> RepositoryDefaultBranchChangeResult {
    guard plan.requiresChange else {
      return result(.unchanged, plan: plan)
    }
    let token = try await pdsClient.serviceAuthToken(
      audience: try knotServiceAudience(plan.repository.knot),
      lxm: Sh.Tangled.RepoSetDefaultBranch.id
    )
    do {
      try await dependencies.setDefaultBranch(
        plan.repository.knot,
        token,
        plan.repository.uri,
        plan.newBranch
      )
      return result(.changed, plan: plan)
    } catch is CancellationError {
      throw CancellationError()
    } catch TangledError.notFound {
      throw TangledError.notImplemented(
        "Knot does not support changing the default branch: \(plan.repository.knot)"
      )
    } catch Sh.Tangled.RepoSetDefaultBranch.Error.unexpected(let code, _)
      where ["MethodNotFound", "NotFound", "XRPCNotSupported"].contains(code ?? "")
    {
      throw TangledError.notImplemented(
        "Knot does not support changing the default branch: \(plan.repository.knot)"
      )
    } catch {
      guard isAmbiguousDefaultBranchWriteFailure(error) else { throw error }
      do {
        let current = try await dependencies.defaultBranch(
          plan.repository.knot,
          plan.repository.did
        )
        if current.name == plan.newBranch {
          return result(.changed, plan: plan)
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        return result(.outcomeUnknown, plan: plan, error: String(describing: error))
      }
      return result(.outcomeUnknown, plan: plan, error: String(describing: error))
    }
  }
}

struct RepositoryDefaultBranchDependencies: Sendable {
  let repository: @Sendable (String) async throws -> TangledRecord<Repository>
  let defaultBranch: @Sendable (String, String) async throws -> GitDefaultBranch
  let branch: @Sendable (String, String, String) async throws -> GitReference
  let setDefaultBranch: @Sendable (String, String, String, String) async throws -> Void
}

extension RepositoryDefaultBranchService {
  private struct ResolvedRepository {
    let record: TangledRecord<Repository>
    let target: RepositoryDefaultBranchTarget
  }

  private func resolvedRepository(_ repository: String) async throws -> ResolvedRepository {
    let record = try await dependencies.repository(repository)
    let uri: ATURI
    do {
      uri = try ATURI(string: record.uri)
    } catch {
      throw TangledError.upstreamFailed("repository record has an invalid AT URI")
    }
    guard let rawDID = record.value.repoDID else {
      throw TangledError.invalidRequest("repository has no repository DID")
    }
    do {
      _ = try DID(string: rawDID)
    } catch {
      throw TangledError.upstreamFailed("repository record has an invalid repository DID")
    }
    return ResolvedRepository(
      record: record,
      target: RepositoryDefaultBranchTarget(
        uri: record.uri,
        did: rawDID,
        name: record.value.name ?? uri.rkey?.rawValue ?? rawDID,
        knot: record.value.knot
      )
    )
  }

  private func result(
    _ outcome: RepositoryDefaultBranchChangeOutcome,
    plan: RepositoryDefaultBranchChangePlan,
    error: String? = nil
  ) -> RepositoryDefaultBranchChangeResult {
    RepositoryDefaultBranchChangeResult(
      outcome: outcome,
      repository: plan.repository,
      oldBranch: plan.oldBranch,
      newBranch: plan.newBranch,
      error: error
    )
  }
}

private func isAmbiguousDefaultBranchWriteFailure(_ error: any Error) -> Bool {
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
