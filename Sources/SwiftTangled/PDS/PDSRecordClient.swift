import Foundation
import SwiftAtproto
import TangledLexicons

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct PDSRecordClient: Sendable {
  private let resolver: any ATPResolver
  private let transport: any HTTPTransport

  public init(
    resolver: any ATPResolver = URLSessionATPResolver(),
    transport: any HTTPTransport = URLSessionTransport()
  ) {
    self.resolver = resolver
    self.transport = transport
  }

  public func repository(uri: String) async throws -> TangledRecord<Repository> {
    let output = try await record(uri: uri, collection: "sh.tangled.repo")
    return try TangledRecordDecoder.repository(
      uri: output.uri.rawValue,
      cid: output.cid?.rawValue,
      value: output.value
    )
  }

  public func repositories(
    ownerDID rawOwnerDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    reverse: Bool = false
  ) async throws -> Page<TangledRecord<Repository>> {
    let ownerDID: DID
    do {
      ownerDID = try DID(string: rawOwnerDID)
    } catch {
      throw TangledError.invalidRequest("invalid repository owner DID: \(rawOwnerDID)")
    }
    if let limit, !(1 ... 100).contains(limit) {
      throw TangledError.invalidRequest("repository record limit must be between 1 and 100")
    }
    let pdsURL = try await pdsURL(for: ownerDID)
    let request = try request(
      pdsURL: pdsURL,
      nsid: Com.Atproto.RepoListRecords.id,
      queryItems: [
        URLQueryItem(name: "repo", value: ownerDID.rawValue),
        URLQueryItem(name: "collection", value: "sh.tangled.repo"),
        URLQueryItem(name: "cursor", value: cursor),
        URLQueryItem(name: "limit", value: limit.map(String.init)),
        URLQueryItem(name: "reverse", value: reverse ? "true" : nil),
      ].filter { $0.value != nil }
    )
    let output: Com.Atproto.RepoListRecords_Output = try await response(for: request)
    return Page(
      items: try output.records.map { record in
        try validate(
          uri: record.uri.rawValue,
          ownerDID: ownerDID,
          collection: "sh.tangled.repo"
        )
        let returnedType = try TangledRecordDecoder.recordType(of: record.value)
        guard returnedType == "sh.tangled.repo" else {
          throw TangledError.upstreamFailed(
            "PDS returned record type \(returnedType), expected sh.tangled.repo"
          )
        }
        return try TangledRecordDecoder.repository(
          uri: record.uri.rawValue,
          cid: record.cid.rawValue,
          value: record.value
        )
      },
      cursor: output.cursor
    )
  }

  public func issue(uri: String) async throws -> TangledRecord<Issue> {
    let output = try await record(uri: uri, collection: Sh.Tangled.RepoIssue.nsId)
    return try TangledRecordDecoder.issue(
      uri: output.uri.rawValue,
      cid: output.cid?.rawValue,
      value: output.value
    )
  }

  public func pullRequest(uri: String) async throws -> TangledRecord<PullRequest> {
    let output = try await record(uri: uri, collection: Sh.Tangled.RepoPull.nsId)
    return try TangledRecordDecoder.pullRequest(
      uri: output.uri.rawValue,
      cid: output.cid?.rawValue,
      value: output.value
    )
  }

  public func artifact(uri: String) async throws -> TangledRecord<Artifact> {
    let output = try await record(uri: uri, collection: Sh.Tangled.RepoArtifact.nsId)
    return try TangledRecordDecoder.artifact(
      uri: output.uri.rawValue,
      cid: output.cid?.rawValue,
      value: output.value
    )
  }
}

extension PDSRecordClient {
  private struct RecordTarget {
    let uri: ATURI
    let ownerDID: DID
    let collection: NSID
    let rkey: RecordKey

    init(uri rawURI: String, expectedCollection: String) throws {
      let uri: ATURI
      do {
        uri = try ATURI(string: rawURI)
      } catch {
        throw TangledError.invalidRequest("invalid record AT URI: \(rawURI)")
      }
      guard case .did(let ownerDID) = uri.authority else {
        throw TangledError.invalidRequest("record AT URI authority must be a DID")
      }
      guard let collection = uri.collection, collection.rawValue == expectedCollection else {
        throw TangledError.invalidRequest(
          "record AT URI must identify a \(expectedCollection) record"
        )
      }
      guard let rkey = uri.rkey else {
        throw TangledError.invalidRequest("record AT URI must include an rkey")
      }
      guard uri.fragment == nil else {
        throw TangledError.invalidRequest("record AT URI must not include a fragment")
      }
      self.uri = uri
      self.ownerDID = ownerDID
      self.collection = collection
      self.rkey = rkey
    }
  }

  private func record(
    uri: String,
    collection: String
  ) async throws -> Com.Atproto.RepoGetRecord_Output {
    let target = try RecordTarget(uri: uri, expectedCollection: collection)
    let pdsURL = try await pdsURL(for: target.ownerDID)
    let request = try request(
      pdsURL: pdsURL,
      nsid: Com.Atproto.RepoGetRecord.id,
      queryItems: [
        URLQueryItem(name: "repo", value: target.ownerDID.rawValue),
        URLQueryItem(name: "collection", value: target.collection.rawValue),
        URLQueryItem(name: "rkey", value: target.rkey.rawValue),
      ]
    )
    let output: Com.Atproto.RepoGetRecord_Output = try await response(for: request)
    try validate(
      uri: output.uri.rawValue,
      ownerDID: target.ownerDID,
      collection: collection,
      rkey: target.rkey
    )
    let returnedType = try TangledRecordDecoder.recordType(of: output.value)
    guard returnedType == collection else {
      throw TangledError.upstreamFailed(
        "PDS returned record type \(returnedType), expected \(collection)"
      )
    }
    return output
  }

  private func pdsURL(for ownerDID: DID) async throws -> URL {
    guard let document = try await resolver.resolve(did: ownerDID) else {
      throw TangledError.handleNotResolved(
        "DID document not found: \(ownerDID.rawValue)"
      )
    }
    guard document.did.typed == ownerDID else {
      throw TangledError.upstreamFailed(
        "DID document does not match \(ownerDID.rawValue)"
      )
    }
    do {
      return try document.pdsUrl
    } catch {
      throw TangledError.handleNotResolved(
        "PDS endpoint not found: \(ownerDID.rawValue)"
      )
    }
  }

  private func request(
    pdsURL: URL,
    nsid: String,
    queryItems: [URLQueryItem]
  ) throws -> URLRequest {
    let endpoint =
      pdsURL
      .appendingPathComponent("xrpc", isDirectory: true)
      .appendingPathComponent(nsid, isDirectory: false)
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw TangledError.invalidRequest("invalid PDS endpoint")
    }
    components.queryItems = queryItems
    guard let url = components.url else {
      throw TangledError.invalidRequest("invalid PDS request for \(nsid)")
    }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private func response<Value: Decodable>(for request: URLRequest) async throws -> Value {
    let data: Data
    let httpResponse: HTTPURLResponse
    do {
      (data, httpResponse) = try await transport.send(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TangledError {
      throw error
    } catch let error as URLError {
      throw TangledError.network(error)
    } catch {
      throw TangledError.transport(String(describing: error))
    }
    guard (200 ... 299).contains(httpResponse.statusCode) else {
      throw mapError(data: data, response: httpResponse)
    }

    do {
      let decoder = JSONDecoder()
      decoder.userInfo[.atprotoLexiconDecodingMode] = LexiconDecodingMode.permissive
      return try decoder.decode(Value.self, from: data)
    } catch {
      throw TangledError.decoding(error)
    }
  }

  private func validate(
    uri rawURI: String,
    ownerDID: DID,
    collection: String,
    rkey: RecordKey? = nil
  ) throws {
    let uri: ATURI
    do {
      uri = try ATURI(string: rawURI)
    } catch {
      throw TangledError.upstreamFailed("PDS returned an invalid record URI")
    }
    guard uri.authority == .did(ownerDID),
      uri.collection?.rawValue == collection,
      uri.rkey != nil,
      uri.fragment == nil,
      rkey == nil || uri.rkey == rkey
    else {
      throw TangledError.upstreamFailed(
        "PDS returned an unexpected record URI: \(rawURI)"
      )
    }
  }

  private func mapError(data: Data, response: HTTPURLResponse) -> TangledError {
    let failure = try? JSONDecoder().decode(PDSRecordFailure.self, from: data)
    let message = failure?.message ?? failure?.error
    if failure?.error == "RecordNotFound" {
      return .notFound(message)
    }
    switch response.statusCode {
    case 400:
      return .invalidRequest(message)
    case 401, 403:
      return .unauthorized
    case 404:
      return .notFound(message)
    case 429:
      return .rateLimited(
        retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init),
        message: message
      )
    case 502:
      return .serviceUnavailable(message)
    case 503:
      return .serviceUnavailable(message)
    default:
      return .serverStatus(response.statusCode, message)
    }
  }
}

private struct PDSRecordFailure: Decodable {
  let error: String?
  let message: String?
}
