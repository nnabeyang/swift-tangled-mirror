import Foundation

public let tangledRepositoryPushMethod = "sh.tangled.repo.push"

public struct GitAuthenticationTarget: Codable, Equatable, Sendable {
  public let repositoryURI: String
  public let repositoryDID: String
  public let knot: String
  public let url: String

  public init(repositoryURI: String, repositoryDID: String, knot: String, url: String) {
    self.repositoryURI = repositoryURI
    self.repositoryDID = repositoryDID
    self.knot = knot
    self.url = url
  }
}

public struct GitCredentialRequest: Equatable, Sendable {
  public let protocolName: String?
  public let host: String?
  public let path: String?

  public init(protocolName: String?, host: String?, path: String?) {
    self.protocolName = protocolName
    self.host = host
    self.path = path
  }
}

public struct GitCredential: Equatable, Sendable {
  public let username: String
  public let password: String

  public init(username: String, password: String) {
    self.username = username
    self.password = password
  }
}

public struct GitAuthenticationService: Sendable {
  private let resolveRepository: @Sendable (String) async throws -> TangledRecord<Repository>

  public init(repositoryLocator: RepositoryLocator = RepositoryLocator()) {
    resolveRepository = { try await repositoryLocator.resolve($0) }
  }

  init(
    resolveRepository: @escaping @Sendable (String) async throws -> TangledRecord<Repository>
  ) {
    self.resolveRepository = resolveRepository
  }

  public func target(for repository: String) async throws -> GitAuthenticationTarget {
    let record = try await resolveRepository(repository)
    guard let repositoryDID = record.value.repoDID else {
      throw TangledError.invalidRequest("repository does not expose a repository DID")
    }
    let knotURL = try normalizedKnotURL(record.value.knot)
    let url = knotURL.appendingPathComponent(repositoryDID, isDirectory: true).absoluteString
    return GitAuthenticationTarget(
      repositoryURI: record.uri,
      repositoryDID: repositoryDID,
      knot: record.value.knot,
      url: url
    )
  }

  public func credential(
    for request: GitCredentialRequest,
    target: GitAuthenticationTarget,
    accountHandle: String,
    pdsClient: PDSClient
  ) async throws -> GitCredential {
    let expected = try credentialComponents(target.url)
    guard request.protocolName?.lowercased() == "https",
      request.host?.lowercased() == expected.host,
      normalizedCredentialPath(request.path) == expected.path
    else {
      throw TangledError.invalidRequest("Git credential request does not match the configured repository")
    }
    let token = try await pdsClient.serviceAuthToken(
      audience: try knotServiceAudience(target.knot),
      lxm: tangledRepositoryPushMethod
    )
    return GitCredential(username: accountHandle, password: token)
  }

  private func normalizedKnotURL(_ knot: String) throws -> URL {
    let raw = knot.contains("://") ? knot : "https://\(knot)"
    guard var components = URLComponents(string: raw),
      components.scheme?.lowercased() == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else { throw TangledError.invalidRequest("repository has an invalid Knot endpoint") }
    components.scheme = "https"
    components.path = "/"
    if components.port == 443 { components.port = nil }
    guard let url = components.url else {
      throw TangledError.invalidRequest("repository has an invalid Knot endpoint")
    }
    return url
  }

  private func credentialComponents(_ rawURL: String) throws -> (host: String, path: String) {
    guard let components = URLComponents(string: rawURL), let host = components.host else {
      throw TangledError.invalidRequest("configured Git URL is invalid")
    }
    let authority = components.port.map { "\(host):\($0)" } ?? host
    return (authority.lowercased(), normalizedCredentialPath(components.path) ?? "")
  }

  private func normalizedCredentialPath(_ path: String?) -> String? {
    guard var path, !path.isEmpty else { return nil }
    path = path.removingPercentEncoding ?? path
    while path.hasPrefix("/") { path.removeFirst() }
    while path.hasSuffix("/") { path.removeLast() }
    return path.isEmpty ? nil : path
  }
}
