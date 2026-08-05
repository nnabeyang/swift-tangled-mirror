import Foundation
import SwiftAtproto
import TangledLexicons

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct RepositoryLocator: Sendable {
  private let client: BobbinClient
  private let identityResolver: any ATPResolver
  private let knotTransport: any HTTPTransport
  private let pdsClient: PDSRecordClient
  private let recordReader: TangledRecordReader

  public init(
    client: BobbinClient = BobbinClient(),
    identityResolver: any ATPResolver = URLSessionATPResolver(),
    knotTransport: any HTTPTransport = URLSessionTransport(),
    pdsTransport: any HTTPTransport = URLSessionTransport()
  ) {
    self.client = client
    self.identityResolver = identityResolver
    self.knotTransport = knotTransport
    let pdsClient = PDSRecordClient(resolver: identityResolver, transport: pdsTransport)
    self.pdsClient = pdsClient
    self.recordReader = TangledRecordReader(pdsClient: pdsClient, bobbinClient: client)
  }

  public func resolve(_ rawReference: String) async throws -> TangledRecord<Repository> {
    let reference: RepositoryReference
    do throws(TangledError) {
      reference = try RepositoryReference(rawReference)
    } catch {
      throw error
    }
    switch reference {
    case .atURI(let uri):
      return try await recordReader.repository(uri: uri).record
    case .repositoryDID(let did):
      do {
        return try await repositoryThroughKnot(repoDID: did)
      } catch is CancellationError {
        throw CancellationError()
      } catch let knotError as TangledError {
        guard knotError.allowsRepositoryDiscoveryFallback else {
          throw knotError
        }
        do {
          let discovered = try await client.repository(repoDID: did)
          let record = try await recordReader.repository(uri: discovered.uri).record
          try validate(record: record, repoDID: did)
          return record
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          throw knotError
        }
      }
    case .ownerAndName(let owner, let name):
      let ownerDID = try await resolveOwnerDID(owner)
      return try await repository(ownerDID: ownerDID, owner: owner, name: name)
    }
  }

  public func resolveOwnerDID(_ rawOwner: String) async throws -> String {
    let owner = rawOwner.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !owner.isEmpty else {
      throw TangledError.invalidRequest("repository owner must not be empty")
    }

    if owner.hasPrefix("did:") {
      do {
        return try DID(string: owner).rawValue
      } catch {
        throw TangledError.invalidRequest("invalid repository owner DID: \(owner)")
      }
    }

    let handle: Handle
    do {
      handle = try Handle(string: owner)
    } catch {
      throw TangledError.invalidRequest("invalid repository owner handle: \(owner)")
    }
    guard let did = try await identityResolver.resolve(handle: handle) else {
      throw TangledError.handleNotResolved(owner)
    }
    return did.rawValue
  }
}

extension RepositoryLocator {
  fileprivate func repositoryThroughKnot(
    repoDID rawRepoDID: String
  ) async throws -> TangledRecord<Repository> {
    let repoDID: DID
    do {
      repoDID = try DID(string: rawRepoDID)
    } catch {
      throw TangledError.invalidRequest("invalid repository DID: \(rawRepoDID)")
    }
    guard let document = try await identityResolver.resolve(did: repoDID) else {
      throw TangledError.handleNotResolved("DID document not found: \(rawRepoDID)")
    }
    let knotURL = try repositoryKnotURL(document: document, repoDID: repoDID)

    let description: Sh.Tangled.RepoDescribeRepo_Output
    do {
      description = try await HTTPXRPCClient(
        baseURL: knotURL,
        transport: knotTransport
      ).RepoDescribeRepo(repoDid: .init(repoDID))
    } catch Sh.Tangled.RepoDescribeRepo.Error.reponotfound {
      throw TangledError.notFound("repository not found on its Knot: \(rawRepoDID)")
    } catch TangledError.notFound {
      throw TangledError.notFound("repository not found on its Knot: \(rawRepoDID)")
    }
    guard description.repoDid.rawValue == rawRepoDID else {
      throw TangledError.upstreamFailed(
        "Knot returned repository DID \(description.repoDid.rawValue), expected \(rawRepoDID)"
      )
    }
    let uri =
      "at://\(description.ownerDid.rawValue)/\(Sh.Tangled.Repo.nsId)/\(description.rkey.rawValue)"
    let record = try await recordReader.repository(uri: uri).record
    try validate(record: record, repoDID: rawRepoDID)
    return record
  }

  private func repositoryKnotURL(document: DIDDocument, repoDID: DID) throws -> URL {
    let tangledKnotID = "\(repoDID.rawValue)#tangled_knot"
    let endpoint: URL
    if let service = (document.service ?? []).first(where: {
      ($0.id == "#tangled_knot" || $0.id == tangledKnotID) && $0.type == "TangledKnot"
    }) {
      guard let url = URL(string: service.serviceEndpoint) else {
        throw TangledError.invalidRequest("Knot endpoint is not a valid HTTPS URL")
      }
      endpoint = url
    } else {
      do {
        endpoint = try document.pdsUrl
      } catch {
        throw TangledError.handleNotResolved(
          "Knot endpoint not found for \(repoDID.rawValue)"
        )
      }
    }

    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else {
      throw TangledError.invalidRequest("Knot endpoint is not a valid HTTPS URL")
    }
    components.scheme = "https"
    components.path = ""
    if components.port == 443 {
      components.port = nil
    }
    guard let knotURL = components.url else {
      throw TangledError.invalidRequest("Knot endpoint is not a valid HTTPS URL")
    }
    return knotURL
  }

  fileprivate func repository(
    ownerDID: String,
    owner: String,
    name: String
  ) async throws -> TangledRecord<Repository> {
    let discovered: SearchHit?
    do {
      discovered = try await repositoryThroughBobbin(ownerDID: ownerDID, name: name)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      discovered = nil
    }
    if let discovered {
      do {
        let record = try await recordReader.repository(uri: discovered.uri).record
        if record.matchesRepositoryName(name) {
          return record
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Bobbin is discovery only. Continue with the owner's authoritative records.
      }
    }

    var cursor: String?
    var seenCursors = Set<String>()
    repeat {
      let page = try await pdsClient.repositories(
        ownerDID: ownerDID,
        cursor: cursor,
        limit: 100
      )
      if let record = page.items.first(where: { $0.matchesRepositoryName(name) }) {
        return record
      }
      guard let nextCursor = page.cursor else { break }
      guard seenCursors.insert(nextCursor).inserted else {
        throw TangledError.upstreamFailed("repository records returned a repeated cursor")
      }
      cursor = nextCursor
    } while true

    throw TangledError.notFound("repository not found: \(owner)/\(name)")
  }

  private func repositoryThroughBobbin(
    ownerDID: String,
    name: String
  ) async throws -> SearchHit {
    var cursor: String?
    var seenCursors = Set<String>()
    repeat {
      let page = try await client.search(
        name,
        options: SearchOptions(
          nsid: Sh.Tangled.Repo.nsId,
          authorDID: ownerDID,
          cursor: cursor,
          limit: 100
        )
      )
      if let hit = page.items.first(where: { $0.matchesRepositoryName(name) }) {
        return hit
      }
      guard let nextCursor = page.cursor else { break }
      guard seenCursors.insert(nextCursor).inserted else {
        throw TangledError.upstreamFailed("repository search returned a repeated cursor")
      }
      cursor = nextCursor
    } while true

    throw TangledError.notFound("repository not found on Bobbin")
  }

  private func validate(
    record: TangledRecord<Repository>,
    repoDID: String
  ) throws {
    guard record.value.repoDID == repoDID else {
      throw TangledError.upstreamFailed(
        "repository record does not match repository DID \(repoDID)"
      )
    }
  }
}

extension SearchHit {
  fileprivate func matchesRepositoryName(_ name: String) -> Bool {
    if case .object(let object) = value,
      case .string(let recordName) = object["name"], recordName == name
    {
      return true
    }
    return (try? ATURI(string: uri).rkey?.rawValue) == name
  }
}

extension TangledRecord where Value == Repository {
  fileprivate func matchesRepositoryName(_ name: String) -> Bool {
    value.name == name || (try? ATURI(string: uri).rkey?.rawValue) == name
  }
}

extension TangledError {
  fileprivate var allowsRepositoryDiscoveryFallback: Bool {
    switch self {
    case .notFound, .network, .transport, .handleNotResolved, .rateLimited,
      .serviceUnavailable:
      true
    case .serverStatus(let statusCode, _):
      statusCode >= 500
    default:
      false
    }
  }
}
