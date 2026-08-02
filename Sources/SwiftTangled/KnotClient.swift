import Foundation
import SwiftAtproto
import TangledLexicons

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct KnotClient: Sendable {
  private let transport: any HTTPTransport

  public init(transport: any HTTPTransport = URLSessionTransport()) {
    self.transport = transport
  }

  public func createRepository(
    knot: String,
    token: String,
    rkey: String,
    name: String,
    defaultBranch: String,
    source: String? = nil,
    repositoryDID: String? = nil
  ) async throws -> String {
    let recordKey = try validRecordKey(rkey)
    let output = try await client(knot: knot, token: token).RepoCreate(
      input: Sh.Tangled.RepoCreate_Input(
        defaultBranch: defaultBranch,
        name: name,
        repoDid: repositoryDID.map(FormatString.init(rawValue:)),
        rkey: FormatString(recordKey),
        source: source
      )
    )
    guard let repositoryDID = output.repoDid?.rawValue, !repositoryDID.isEmpty else {
      throw TangledError.decoding(RepositoryLifecycleError.missingRepositoryDID)
    }
    return repositoryDID
  }

  public func deleteRepository(
    knot: String,
    token: String,
    ownerDID: String,
    name: String,
    rkey: String
  ) async throws {
    let recordKey = try validRecordKey(rkey)
    _ = try await client(knot: knot, token: token).RepoDelete(
      input: Sh.Tangled.RepoDelete_Input(
        did: FormatString(rawValue: ownerDID),
        name: name,
        rkey: FormatString(recordKey)
      )
    )
  }

  public func capabilities(knot: String) async throws -> Set<String> {
    let output = try await client(knot: knot).KnotVersion()
    return Set(output.capabilities ?? [])
  }

  public func defaultBranch(
    knot: String,
    repositoryDID: String
  ) async throws -> GitDefaultBranch {
    let repositoryDID = try validDID(repositoryDID, name: "repository DID")
    let output = try await client(knot: knot).RepoGetDefaultBranch(repo: repositoryDID.rawValue)
    return GitDefaultBranch(
      name: output.name,
      hash: output.hash,
      shortHash: output.shortHash,
      when: output.when,
      message: output.message,
      author: output.author.map {
        GitSignature(name: $0.name, email: $0.email, when: $0.when)
      }
    )
  }

  public func branch(
    knot: String,
    repositoryDID: String,
    name: String
  ) async throws -> GitReference {
    let repositoryDID = try validDID(repositoryDID, name: "repository DID")
    let name = try required(name, name: "branch")
    let output = try await client(knot: knot).RepoBranch(
      name: name,
      repo: repositoryDID.rawValue
    )
    return GitReference(name: output.name, hash: output.hash)
  }

  public func setDefaultBranch(
    knot: String,
    token: String,
    repositoryURI: String,
    branch: String
  ) async throws {
    guard let repositoryURI = FormatString<ATURI>(rawValue: repositoryURI).typed else {
      throw TangledError.invalidRequest("repository URI must be a valid AT URI")
    }
    let branch = try required(branch, name: "branch")
    _ = try await client(knot: knot, token: token).RepoSetDefaultBranch(
      input: Sh.Tangled.RepoSetDefaultBranch_Input(
        defaultBranch: branch,
        repo: FormatString(repositoryURI)
      )
    )
  }

  public func collaborators(
    knot: String,
    repositoryDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<RepositoryCollaborator> {
    let repositoryDID = try validDID(repositoryDID, name: "repository DID")
    let output = try await client(knot: knot).RepoListCollaborators(
      cursor: cursor,
      limit: limit,
      order: Sh.Tangled.RepoListCollaborators_Order(rawValue: order.rawValue),
      subject: FormatString(repositoryDID)
    )
    return Page(
      items: output.items.map {
        RepositoryCollaborator(
          subjectDID: $0.subject.rawValue,
          addedByDID: $0.addedBy.rawValue,
          createdAt: $0.createdAt,
          recordURI: $0.uri?.rawValue,
          recordCID: $0.cid?.rawValue
        )
      },
      cursor: output.cursor
    )
  }

  public func addCollaborator(
    knot: String,
    token: String,
    repositoryDID: String,
    collaboratorDID: String
  ) async throws {
    let repositoryDID = try validDID(repositoryDID, name: "repository DID")
    let collaboratorDID = try validDID(collaboratorDID, name: "collaborator DID")
    _ = try await client(knot: knot, token: token).RepoAddCollaborator(
      input: Sh.Tangled.RepoAddCollaborator_Input(
        repo: FormatString(repositoryDID),
        subject: FormatString(collaboratorDID)
      )
    )
  }

  public func removeCollaborator(
    knot: String,
    token: String,
    repositoryDID: String,
    collaboratorDID: String
  ) async throws {
    let repositoryDID = try validDID(repositoryDID, name: "repository DID")
    let collaboratorDID = try validDID(collaboratorDID, name: "collaborator DID")
    _ = try await client(knot: knot, token: token).RepoRemoveCollaborator(
      input: Sh.Tangled.RepoRemoveCollaborator_Input(
        repo: FormatString(repositoryDID),
        subject: FormatString(collaboratorDID)
      )
    )
  }

  public func mergeCheck(
    knot: String,
    ownerDID: String,
    repositoryName: String,
    repositoryDID: String,
    branch: String,
    patch: String
  ) async throws -> PullRequestMergeCheckResponse {
    let input = Sh.Tangled.RepoMergeCheck_Input(
      branch: branch,
      did: FormatString(rawValue: ownerDID),
      name: repositoryName,
      patch: patch,
      repo: FormatString(rawValue: repositoryDID)
    )
    let output = try await client(knot: knot).RepoMergeCheck(input: input)
    return PullRequestMergeCheckResponse(
      isConflicted: output.is_conflicted,
      conflicts: (output.conflicts ?? []).map {
        PullRequestMergeConflict(filename: $0.filename, reason: $0.reason)
      },
      message: output.message,
      error: output.error
    )
  }

  public func merge(
    knot: String,
    token: String,
    ownerDID: String,
    repositoryName: String,
    repositoryDID: String,
    branch: String,
    patch: String,
    commitMessage: String,
    commitBody: String?
  ) async throws {
    let input = Sh.Tangled.RepoMerge_Input(
      branch: branch,
      commitBody: commitBody,
      commitMessage: commitMessage,
      did: FormatString(rawValue: ownerDID),
      name: repositoryName,
      patch: patch,
      repo: FormatString(rawValue: repositoryDID)
    )
    _ = try await client(knot: knot, token: token).RepoMerge(input: input)
  }

  public func updateHiddenRef(
    knot: String,
    token: String,
    repositoryURI: String,
    sourceBranch: String,
    targetBranch: String
  ) async throws -> String {
    let sourceBranch = try required(sourceBranch, name: "source branch")
    let targetBranch = try required(targetBranch, name: "target branch")
    let expectedRef = "hidden/\(sourceBranch)/\(targetBranch)"
    let input = Sh.Tangled.RepoHiddenRef_Input(
      forkRef: sourceBranch,
      remoteRef: targetBranch,
      repo: FormatString(rawValue: repositoryURI)
    )
    let output = try await client(knot: knot, token: token).RepoHiddenRef(input: input)
    guard output.success else {
      throw TangledError.upstreamFailed(
        output.error ?? "Knot failed to update the hidden tracking ref"
      )
    }
    if let returnedRef = output.ref, returnedRef != expectedRef {
      throw TangledError.upstreamFailed(
        "Knot returned a different hidden tracking ref: \(returnedRef)"
      )
    }
    return expectedRef
  }

  public func compare(
    knot: String,
    repositoryDID: String,
    baseRevision: String,
    headRevision: String
  ) async throws -> GitComparison {
    let repositoryDID = try required(repositoryDID, name: "repository DID")
    let baseRevision = try required(baseRevision, name: "base revision")
    let headRevision = try required(headRevision, name: "head revision")
    let data = try await client(knot: knot).RepoCompare(
      repo: repositoryDID,
      rev1: baseRevision,
      rev2: headRevision
    )
    return try decodeGitComparison(from: data)
  }
}

public struct PullRequestMergeCheckResponse: Equatable, Sendable {
  public let isConflicted: Bool
  public let conflicts: [PullRequestMergeConflict]
  public let message: String?
  public let error: String?

  public init(
    isConflicted: Bool,
    conflicts: [PullRequestMergeConflict] = [],
    message: String? = nil,
    error: String? = nil
  ) {
    self.isConflicted = isConflicted
    self.conflicts = conflicts
    self.message = message
    self.error = error
  }
}

func knotServiceAudience(_ knot: String) throws(TangledError) -> String {
  let rawValue = knot.contains("://") ? knot : "https://\(knot)"
  guard let url = URL(string: rawValue),
    url.scheme?.lowercased() == "https",
    let host = url.host,
    url.path.isEmpty || url.path == "/"
  else {
    throw TangledError.invalidRequest("invalid Knot endpoint: \(knot)")
  }
  let authority =
    if let port = url.port {
      "\(host):\(port)".replacingOccurrences(of: ":", with: "%3A")
    } else {
      host
    }
  return "did:web:\(authority)"
}

extension KnotClient {
  fileprivate func client(
    knot: String,
    token: String? = nil
  ) throws(TangledError) -> HTTPXRPCClient {
    HTTPXRPCClient(
      baseURL: try knotBaseURL(knot),
      transport: transport,
      bearerToken: token,
      conflictMessage: "merge conflict"
    )
  }

  fileprivate func knotBaseURL(_ value: String) throws(TangledError) -> URL {
    let rawValue = value.contains("://") ? value : "https://\(value)"
    guard let url = URL(string: rawValue),
      url.scheme?.lowercased() == "https",
      url.host != nil
    else {
      throw TangledError.invalidRequest("invalid Knot endpoint: \(value)")
    }
    return url
  }

  private func required(_ value: String, name: String) throws(TangledError) -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      throw TangledError.invalidRequest("\(name) must not be empty")
    }
    return value
  }

  private func validDID(_ value: String, name: String) throws(TangledError) -> DID {
    do {
      return try DID(string: value)
    } catch {
      throw TangledError.invalidRequest("\(name) must be a valid DID")
    }
  }

  private func validRecordKey(_ value: String) throws(TangledError) -> RecordKey {
    do {
      return try RecordKey(string: value)
    } catch {
      throw TangledError.invalidRequest("invalid repository record key: \(value)")
    }
  }
}
