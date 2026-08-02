import SwiftAtproto
import TangledLexicons

extension SpindleClient {
  package func repositorySecrets(
    repositoryURI: String,
    token: String
  ) async throws -> [RepositorySecret] {
    let uri = try repositoryATURI(repositoryURI)
    let client = authenticatedClient(token: token)
    let output = try await client.RepoListSecrets(repo: FormatString(uri))
    return (output.secrets ?? []).map {
      RepositorySecret(
        repositoryURI: $0.repo.rawValue,
        key: $0.key,
        createdAt: $0.createdAt,
        createdByDID: $0.createdBy.rawValue
      )
    }
  }

  package func addRepositorySecret(
    repositoryURI: String,
    key: String,
    value: String,
    token: String
  ) async throws {
    let input = try Sh.Tangled.RepoAddSecret_Input.make(
      key: key,
      repo: FormatString(try repositoryATURI(repositoryURI)),
      value: value
    )
    _ = try await authenticatedClient(token: token).RepoAddSecret(input: input)
  }

  package func removeRepositorySecret(
    repositoryURI: String,
    key: String,
    token: String
  ) async throws {
    let input = try Sh.Tangled.RepoRemoveSecret_Input.make(
      key: key,
      repo: FormatString(try repositoryATURI(repositoryURI))
    )
    _ = try await authenticatedClient(token: token).RepoRemoveSecret(input: input)
  }

  private func authenticatedClient(token: String) -> HTTPXRPCClient {
    HTTPXRPCClient(baseURL: baseURL, transport: transport, bearerToken: token)
  }
}

package func validateRepositorySecretKey(repositoryURI: String, key: String) throws {
  _ = try Sh.Tangled.RepoRemoveSecret_Input.make(
    key: key,
    repo: FormatString(try repositoryATURI(repositoryURI))
  )
}

package func validateRepositorySecretInput(
  repositoryURI: String,
  key: String,
  value: String
) throws {
  _ = try Sh.Tangled.RepoAddSecret_Input.make(
    key: key,
    repo: FormatString(try repositoryATURI(repositoryURI)),
    value: value
  )
}

private func repositoryATURI(_ value: String) throws(TangledError) -> ATURI {
  do {
    return try ATURI(string: value)
  } catch {
    throw TangledError.invalidRequest("repository record must have a valid AT URI")
  }
}
