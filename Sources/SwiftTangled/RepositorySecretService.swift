import Foundation
import SwiftAtproto
import TangledLexicons

public struct RepositorySecretService: Sendable {
  private let dependencies: RepositorySecretDependencies

  public init(repositoryLocator: RepositoryLocator = RepositoryLocator()) {
    dependencies = RepositorySecretDependencies(
      repository: { try await repositoryLocator.resolve($0) },
      list: { spindle, token, repositoryURI in
        try await SpindleClient(spindle: spindle).repositorySecrets(
          repositoryURI: repositoryURI,
          token: token
        )
      },
      add: { spindle, token, repositoryURI, key, value in
        try await SpindleClient(spindle: spindle).addRepositorySecret(
          repositoryURI: repositoryURI,
          key: key,
          value: value,
          token: token
        )
      },
      remove: { spindle, token, repositoryURI, key in
        try await SpindleClient(spindle: spindle).removeRepositorySecret(
          repositoryURI: repositoryURI,
          key: key,
          token: token
        )
      },
      validateKey: { repositoryURI, key in
        try validateRepositorySecretKey(repositoryURI: repositoryURI, key: key)
      },
      serviceAudience: { try spindleServiceAudience(SpindleClient(spindle: $0).baseURL) }
    )
  }

  init(dependencies: RepositorySecretDependencies) {
    self.dependencies = dependencies
  }

  public func secrets(
    repository: String,
    spindle: String? = nil,
    pdsClient: PDSClient
  ) async throws -> RepositorySecretList {
    let resolved = try await resolvedRepository(repository, spindle: spindle)
    let token = try await serviceToken(
      pdsClient: pdsClient,
      spindle: resolved.spindle,
      lxm: Sh.Tangled.RepoListSecrets.id
    )
    return RepositorySecretList(
      repositoryURI: resolved.uri,
      repositoryName: resolved.name,
      spindle: resolved.spindle,
      secrets: try await dependencies.list(resolved.spindle, token, resolved.uri)
    )
  }

  public func prepareAddition(
    repository: String,
    spindle: String? = nil,
    key: String,
    pdsClient: PDSClient
  ) async throws -> RepositorySecretAdditionPlan {
    let target = try await target(repository: repository, spindle: spindle, key: key)
    _ = try await serviceToken(
      pdsClient: pdsClient,
      spindle: target.spindle,
      lxm: Sh.Tangled.RepoAddSecret.id
    )
    return RepositorySecretAdditionPlan(
      target: target,
      isPresent: try await containsSecret(target, pdsClient: pdsClient)
    )
  }

  public func add(
    _ plan: RepositorySecretAdditionPlan,
    value: String,
    pdsClient: PDSClient
  ) async throws -> RepositorySecretMutationResult {
    guard !plan.isPresent else {
      return RepositorySecretMutationResult(outcome: .alreadyPresent, target: plan.target)
    }
    do {
      try validateRepositorySecretInput(
        repositoryURI: plan.target.repositoryURI,
        key: plan.target.key,
        value: value
      )
    } catch {
      throw TangledError.invalidRequest(String(describing: error))
    }
    let token = try await serviceToken(
      pdsClient: pdsClient,
      spindle: plan.target.spindle,
      lxm: Sh.Tangled.RepoAddSecret.id
    )
    do {
      try await dependencies.add(
        plan.target.spindle,
        token,
        plan.target.repositoryURI,
        plan.target.key,
        value
      )
      return RepositorySecretMutationResult(outcome: .added, target: plan.target)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if isAmbiguousSecretWriteFailure(error) {
        return RepositorySecretMutationResult(outcome: .outcomeUnknown, target: plan.target)
      }
      throw redacting(error, secret: value)
    }
  }

  public func prepareRemoval(
    repository: String,
    spindle: String? = nil,
    key: String,
    pdsClient: PDSClient
  ) async throws -> RepositorySecretRemovalPlan {
    let target = try await target(repository: repository, spindle: spindle, key: key)
    _ = try await serviceToken(
      pdsClient: pdsClient,
      spindle: target.spindle,
      lxm: Sh.Tangled.RepoRemoveSecret.id
    )
    return RepositorySecretRemovalPlan(
      target: target,
      isPresent: try await containsSecret(target, pdsClient: pdsClient)
    )
  }

  public func remove(
    _ plan: RepositorySecretRemovalPlan,
    pdsClient: PDSClient
  ) async throws -> RepositorySecretMutationResult {
    guard plan.isPresent else {
      return RepositorySecretMutationResult(outcome: .notPresent, target: plan.target)
    }
    let token = try await serviceToken(
      pdsClient: pdsClient,
      spindle: plan.target.spindle,
      lxm: Sh.Tangled.RepoRemoveSecret.id
    )
    do {
      try await dependencies.remove(
        plan.target.spindle,
        token,
        plan.target.repositoryURI,
        plan.target.key
      )
      return RepositorySecretMutationResult(outcome: .removed, target: plan.target)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard isAmbiguousSecretWriteFailure(error) else { throw error }
      return RepositorySecretMutationResult(outcome: .outcomeUnknown, target: plan.target)
    }
  }
}

struct RepositorySecretDependencies: Sendable {
  let repository: @Sendable (String) async throws -> TangledRecord<Repository>
  let list: @Sendable (String, String, String) async throws -> [RepositorySecret]
  let add: @Sendable (String, String, String, String, String) async throws -> Void
  let remove: @Sendable (String, String, String, String) async throws -> Void
  let validateKey: @Sendable (String, String) throws -> Void
  let serviceAudience: @Sendable (String) throws -> String
}

extension RepositorySecretService {
  private struct ResolvedRepository {
    let uri: String
    let name: String
    let spindle: String
  }

  private func resolvedRepository(
    _ repository: String,
    spindle: String?
  ) async throws -> ResolvedRepository {
    let record = try await dependencies.repository(repository)
    let uri: ATURI
    do {
      uri = try ATURI(string: record.uri)
    } catch {
      throw TangledError.upstreamFailed("repository record has an invalid AT URI")
    }
    let resolvedSpindle: String
    if let spindle {
      resolvedSpindle = try SpindleClient(spindle: spindle).baseURL.absoluteString
    } else if let spindle = record.value.spindle, !spindle.isEmpty {
      resolvedSpindle = try SpindleClient(spindle: spindle).baseURL.absoluteString
    } else {
      throw TangledError.invalidRequest("repository does not expose a Spindle: \(record.uri)")
    }
    return ResolvedRepository(
      uri: record.uri,
      name: record.value.name ?? uri.rkey?.rawValue ?? record.uri,
      spindle: resolvedSpindle
    )
  }

  private func target(
    repository: String,
    spindle: String?,
    key: String
  ) async throws -> RepositorySecretTarget {
    let resolved = try await resolvedRepository(repository, spindle: spindle)
    do {
      try dependencies.validateKey(resolved.uri, key)
    } catch {
      throw TangledError.invalidRequest(String(describing: error))
    }
    return RepositorySecretTarget(
      repositoryURI: resolved.uri,
      repositoryName: resolved.name,
      spindle: resolved.spindle,
      key: key
    )
  }

  private func containsSecret(
    _ target: RepositorySecretTarget,
    pdsClient: PDSClient
  ) async throws -> Bool {
    let token = try await serviceToken(
      pdsClient: pdsClient,
      spindle: target.spindle,
      lxm: Sh.Tangled.RepoListSecrets.id
    )
    return try await dependencies.list(target.spindle, token, target.repositoryURI)
      .contains { $0.key == target.key }
  }

  private func serviceToken(
    pdsClient: PDSClient,
    spindle: String,
    lxm: String
  ) async throws -> String {
    try await pdsClient.serviceAuthToken(
      audience: try dependencies.serviceAudience(spindle),
      lxm: lxm
    )
  }
}

private func isAmbiguousSecretWriteFailure(_ error: any Error) -> Bool {
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

private func redacting(_ error: any Error, secret: String) -> TangledError {
  let description =
    secret.isEmpty
    ? String(describing: error)
    : String(describing: error).replacingOccurrences(of: secret, with: "[REDACTED]")
  return TangledError.upstreamFailed(description)
}
