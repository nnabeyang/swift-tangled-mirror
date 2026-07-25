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

  public init(
    client: BobbinClient = BobbinClient(),
    identityResolver: any ATPResolver = URLSessionATPResolver(),
    knotTransport: any HTTPTransport = URLSessionTransport()
  ) {
    self.client = client
    self.identityResolver = identityResolver
    self.knotTransport = knotTransport
  }

  public func resolve(_ rawReference: String) async throws -> TangledRecord<Repository> {
    let reference = try RepositoryReference(rawReference)
    switch reference {
    case .atURI(let uri):
      return try await client.repository(uri: uri)
    case .repositoryDID(let did):
      do {
        return try await client.repository(repoDID: did)
      } catch TangledError.notFound {
        return try await repositoryThroughKnot(repoDID: did)
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
    let knotURL: URL
    do {
      knotURL = try document.pdsUrl
    } catch {
      throw TangledError.handleNotResolved("Knot endpoint not found for \(rawRepoDID)")
    }
    guard knotURL.scheme?.lowercased() == "https" else {
      throw TangledError.invalidRequest("Knot endpoint must use HTTPS")
    }

    let endpoint =
      knotURL
      .appendingPathComponent("xrpc", isDirectory: true)
      .appendingPathComponent(Sh.Tangled.RepoDescribeRepo.id, isDirectory: false)
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw TangledError.invalidRequest("invalid Knot endpoint")
    }
    components.queryItems = [URLQueryItem(name: "repoDid", value: rawRepoDID)]
    guard let url = components.url else {
      throw TangledError.invalidRequest("invalid Knot describeRepo request")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await knotTransport.send(request)
    } catch let error as TangledError {
      throw error
    } catch let error as URLError {
      throw TangledError.network(error)
    } catch {
      throw TangledError.transport(String(describing: error))
    }
    guard (200 ... 299).contains(response.statusCode) else {
      if response.statusCode == 404 {
        throw TangledError.notFound("repository not found on Bobbin or its Knot: \(rawRepoDID)")
      }
      throw TangledError.serverStatus(response.statusCode, "Knot describeRepo failed")
    }

    let description: Sh.Tangled.RepoDescribeRepo_Output
    do {
      description = try JSONDecoder().decode(
        Sh.Tangled.RepoDescribeRepo_Output.self,
        from: data
      )
    } catch {
      throw TangledError.decoding(error)
    }
    guard description.repoDid.rawValue == rawRepoDID else {
      throw TangledError.upstreamFailed(
        "Knot returned repository DID \(description.repoDid.rawValue), expected \(rawRepoDID)"
      )
    }
    let uri =
      "at://\(description.ownerDid.rawValue)/sh.tangled.repo/\(description.rkey.rawValue)"
    let record = try await client.repository(uri: uri)
    guard record.value.repoDID == rawRepoDID else {
      throw TangledError.upstreamFailed(
        "repository record does not match Knot repository DID \(rawRepoDID)"
      )
    }
    return record
  }

  fileprivate func repository(
    ownerDID: String,
    owner: String,
    name: String
  ) async throws -> TangledRecord<Repository> {
    var cursor: String?
    var seenCursors = Set<String>()
    repeat {
      let page = try await client.search(
        name,
        options: SearchOptions(
          nsid: "sh.tangled.repo",
          authorDID: ownerDID,
          cursor: cursor,
          limit: 100
        )
      )
      if let hit = page.items.first(where: { $0.matchesRepositoryName(name) }) {
        return try await client.repository(uri: hit.uri)
      }
      guard let nextCursor = page.cursor else { break }
      guard seenCursors.insert(nextCursor).inserted else {
        throw TangledError.upstreamFailed("repository search returned a repeated cursor")
      }
      cursor = nextCursor
    } while true

    throw TangledError.notFound("repository not found: \(owner)/\(name)")
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
