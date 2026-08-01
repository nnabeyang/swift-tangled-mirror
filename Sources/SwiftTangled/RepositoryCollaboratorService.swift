import Foundation
import SwiftAtproto
import TangledLexicons

public struct RepositoryCollaboratorService: Sendable {
  private let dependencies: RepositoryCollaboratorDependencies

  public init(
    repositoryLocator: RepositoryLocator = RepositoryLocator(),
    identityResolver: any ATPResolver = URLSessionATPResolver(),
    knotClient: KnotClient = KnotClient()
  ) {
    dependencies = RepositoryCollaboratorDependencies(
      repository: { try await repositoryLocator.resolve($0) },
      resolveCollaboratorDID: { try await resolveCollaboratorDID($0, resolver: identityResolver) },
      capabilities: { try await knotClient.capabilities(knot: $0) },
      collaborators: { knot, repositoryDID, cursor, limit, order in
        try await knotClient.collaborators(
          knot: knot,
          repositoryDID: repositoryDID,
          cursor: cursor,
          limit: limit,
          order: order
        )
      },
      add: { knot, token, repositoryDID, collaboratorDID in
        try await knotClient.addCollaborator(
          knot: knot,
          token: token,
          repositoryDID: repositoryDID,
          collaboratorDID: collaboratorDID
        )
      },
      remove: { knot, token, repositoryDID, collaboratorDID in
        try await knotClient.removeCollaborator(
          knot: knot,
          token: token,
          repositoryDID: repositoryDID,
          collaboratorDID: collaboratorDID
        )
      }
    )
  }

  init(dependencies: RepositoryCollaboratorDependencies) {
    self.dependencies = dependencies
  }

  public func collaborators(
    repository: String,
    cursor: String? = nil,
    limit: Int = 30,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<RepositoryCollaborator> {
    guard (1 ... 1_000).contains(limit) else {
      throw TangledError.invalidRequest("limit must be between 1 and 1000")
    }
    let resolved = try await resolvedRepository(repository)
    try await requireCollaboratorCapability(knot: resolved.knot)
    return try await dependencies.collaborators(
      resolved.knot,
      resolved.repositoryDID,
      cursor,
      limit,
      order
    )
  }

  public func add(
    repository: String,
    collaborator: String,
    pdsClient: PDSClient
  ) async throws -> RepositoryCollaboratorMutationResult {
    let target = try await target(repository: repository, collaborator: collaborator)
    try await requireCollaboratorCapability(knot: target.knot)
    let alreadyPresent = try await containsCollaborator(target)
    let token = try await pdsClient.serviceAuthToken(
      audience: try knotServiceAudience(target.knot),
      lxm: Sh.Tangled.RepoAddCollaborator.id
    )
    do {
      try await dependencies.add(
        target.knot,
        token,
        target.repositoryDID,
        target.collaboratorDID
      )
      return RepositoryCollaboratorMutationResult(
        outcome: alreadyPresent ? .alreadyPresent : .added,
        target: target
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard isAmbiguousCollaboratorWriteFailure(error) else { throw error }
      return RepositoryCollaboratorMutationResult(
        outcome: .outcomeUnknown,
        target: target,
        error: String(describing: error)
      )
    }
  }

  public func prepareRemoval(
    repository: String,
    collaborator: String,
    pdsClient: PDSClient
  ) async throws -> RepositoryCollaboratorRemovalPlan {
    let target = try await target(repository: repository, collaborator: collaborator)
    try await requireCollaboratorCapability(knot: target.knot)
    _ = try await pdsClient.serviceAuthToken(
      audience: try knotServiceAudience(target.knot),
      lxm: Sh.Tangled.RepoRemoveCollaborator.id
    )
    return RepositoryCollaboratorRemovalPlan(
      target: target,
      isPresent: try await containsCollaborator(target)
    )
  }

  public func remove(
    _ plan: RepositoryCollaboratorRemovalPlan,
    pdsClient: PDSClient
  ) async throws -> RepositoryCollaboratorMutationResult {
    guard plan.isPresent else {
      return RepositoryCollaboratorMutationResult(
        outcome: .notPresent,
        target: plan.target
      )
    }
    let token = try await pdsClient.serviceAuthToken(
      audience: try knotServiceAudience(plan.target.knot),
      lxm: Sh.Tangled.RepoRemoveCollaborator.id
    )
    do {
      try await dependencies.remove(
        plan.target.knot,
        token,
        plan.target.repositoryDID,
        plan.target.collaboratorDID
      )
      return RepositoryCollaboratorMutationResult(outcome: .removed, target: plan.target)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard isAmbiguousCollaboratorWriteFailure(error) else { throw error }
      return RepositoryCollaboratorMutationResult(
        outcome: .outcomeUnknown,
        target: plan.target,
        error: String(describing: error)
      )
    }
  }
}

struct RepositoryCollaboratorDependencies: Sendable {
  let repository: @Sendable (String) async throws -> TangledRecord<Repository>
  let resolveCollaboratorDID: @Sendable (String) async throws -> String
  let capabilities: @Sendable (String) async throws -> Set<String>
  let collaborators:
    @Sendable (String, String, String?, Int, BobbinSortOrder) async throws -> Page<
      RepositoryCollaborator
    >
  let add: @Sendable (String, String, String, String) async throws -> Void
  let remove: @Sendable (String, String, String, String) async throws -> Void
}

extension RepositoryCollaboratorService {
  private struct ResolvedRepository {
    let uri: String
    let repositoryDID: String
    let name: String
    let ownerDID: String
    let knot: String
  }

  private func target(
    repository: String,
    collaborator: String
  ) async throws -> RepositoryCollaboratorTarget {
    let resolved = try await resolvedRepository(repository)
    let collaboratorDID = try await dependencies.resolveCollaboratorDID(collaborator)
    guard collaboratorDID != resolved.ownerDID else {
      throw TangledError.invalidRequest("the repository owner cannot be a collaborator")
    }
    return RepositoryCollaboratorTarget(
      repositoryURI: resolved.uri,
      repositoryDID: resolved.repositoryDID,
      repositoryName: resolved.name,
      ownerDID: resolved.ownerDID,
      knot: resolved.knot,
      collaboratorDID: collaboratorDID
    )
  }

  private func resolvedRepository(_ repository: String) async throws -> ResolvedRepository {
    let record = try await dependencies.repository(repository)
    let uri: ATURI
    do {
      uri = try ATURI(string: record.uri)
    } catch {
      throw TangledError.upstreamFailed("repository record has an invalid AT URI")
    }
    guard let rawRepositoryDID = record.value.repoDID else {
      throw TangledError.invalidRequest("repository has no repository DID")
    }
    let repositoryDID: DID
    do {
      repositoryDID = try DID(string: rawRepositoryDID)
    } catch {
      throw TangledError.upstreamFailed("repository record has an invalid repository DID")
    }
    let name = record.value.name ?? uri.rkey?.rawValue ?? repositoryDID.rawValue
    return ResolvedRepository(
      uri: record.uri,
      repositoryDID: repositoryDID.rawValue,
      name: name,
      ownerDID: uri.authority.rawValue,
      knot: record.value.knot
    )
  }

  private func requireCollaboratorCapability(knot: String) async throws {
    let capabilities = try await dependencies.capabilities(knot)
    guard capabilities.contains("knot-acl") else {
      throw TangledError.notImplemented(
        "Knot does not advertise the knot-acl capability: \(knot)"
      )
    }
  }

  private func containsCollaborator(
    _ target: RepositoryCollaboratorTarget
  ) async throws -> Bool {
    var cursor: String?
    var seenCursors = Set<String>()
    repeat {
      let page = try await dependencies.collaborators(
        target.knot,
        target.repositoryDID,
        cursor,
        1_000,
        .descending
      )
      if page.items.contains(where: { $0.subjectDID == target.collaboratorDID }) {
        return true
      }
      guard let next = page.cursor else { return false }
      guard seenCursors.insert(next).inserted else {
        throw TangledError.upstreamFailed("collaborators returned a repeated cursor")
      }
      cursor = next
    } while true
  }
}

package func resolveCollaboratorDID(
  _ rawValue: String,
  resolver: any ATPResolver
) async throws -> String {
  let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !value.isEmpty else {
    throw TangledError.invalidRequest("collaborator must not be empty")
  }
  if value.hasPrefix("did:") {
    do {
      return try DID(string: value).rawValue
    } catch {
      throw TangledError.invalidRequest("invalid collaborator DID: \(value)")
    }
  }
  let rawHandle = value.hasPrefix("@") ? String(value.dropFirst()) : value
  let handle: Handle
  do {
    handle = try Handle(string: rawHandle)
  } catch {
    throw TangledError.invalidRequest("invalid collaborator handle: \(value)")
  }
  guard let did = try await resolver.resolve(handle: handle) else {
    throw TangledError.handleNotResolved(rawHandle)
  }
  return did.rawValue
}

private func isAmbiguousCollaboratorWriteFailure(_ error: any Error) -> Bool {
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
