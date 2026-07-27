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
    let (ownerDID, output) = try await records(
      ownerDID: rawOwnerDID,
      collection: "sh.tangled.repo",
      cursor: cursor,
      limit: limit,
      reverse: reverse
    )
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

  public func pullRequests(
    ownerDID rawOwnerDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    reverse: Bool = false
  ) async throws -> Page<TangledRecord<PullRequest>> {
    let collection = Sh.Tangled.RepoPull.nsId
    let (ownerDID, output) = try await records(
      ownerDID: rawOwnerDID,
      collection: collection,
      cursor: cursor,
      limit: limit,
      reverse: reverse
    )
    return Page(
      items: try output.records.map { record in
        try validate(
          uri: record.uri.rawValue,
          ownerDID: ownerDID,
          collection: collection
        )
        let returnedType = try TangledRecordDecoder.recordType(of: record.value)
        guard returnedType == collection else {
          throw TangledError.upstreamFailed(
            "PDS returned record type \(returnedType), expected \(collection)"
          )
        }
        return try TangledRecordDecoder.pullRequest(
          uri: record.uri.rawValue,
          cid: record.cid.rawValue,
          value: record.value
        )
      },
      cursor: output.cursor
    )
  }

  public func pullRequestStatuses(
    ownerDID rawOwnerDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    reverse: Bool = false
  ) async throws -> Page<TangledRecord<PullRequestStatusChange>> {
    let collection = Sh.Tangled.Repo.PullStatus.nsId
    let (ownerDID, output) = try await records(
      ownerDID: rawOwnerDID,
      collection: collection,
      cursor: cursor,
      limit: limit,
      reverse: reverse
    )
    return Page(
      items: try output.records.map { record in
        try validate(
          uri: record.uri.rawValue,
          ownerDID: ownerDID,
          collection: collection
        )
        let returnedType = try TangledRecordDecoder.recordType(of: record.value)
        guard returnedType == collection else {
          throw TangledError.upstreamFailed(
            "PDS returned record type \(returnedType), expected \(collection)"
          )
        }
        return try TangledRecordDecoder.pullRequestStatus(
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
  private func records(
    ownerDID rawOwnerDID: String,
    collection: String,
    cursor: String?,
    limit: Int?,
    reverse: Bool
  ) async throws -> (DID, Com.Atproto.RepoListRecords_Output) {
    let ownerDID: DID
    do {
      ownerDID = try DID(string: rawOwnerDID)
    } catch {
      throw TangledError.invalidRequest("invalid record owner DID: \(rawOwnerDID)")
    }
    if let limit, !(1 ... 100).contains(limit) {
      throw TangledError.invalidRequest("PDS record limit must be between 1 and 100")
    }
    let pdsURL = try await pdsURL(for: ownerDID)
    let output = try await decode {
      try await PDSRecordXRPCClient(
        baseURL: pdsURL,
        transport: transport
      ).RepoListRecords(
        collection: FormatString(rawValue: collection),
        cursor: cursor,
        limit: limit,
        repo: FormatString(rawValue: ownerDID.rawValue),
        reverse: reverse
      )
    }
    return (ownerDID, output)
  }

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
    let output: Com.Atproto.RepoGetRecord_Output
    do {
      output = try await decode {
        try await PDSRecordXRPCClient(
          baseURL: pdsURL,
          transport: transport
        ).RepoGetRecord(
          collection: FormatString(target.collection),
          repo: FormatString(rawValue: target.ownerDID.rawValue),
          rkey: FormatString(target.rkey)
        )
      }
    } catch Com.Atproto.RepoGetRecord.Error.recordnotfound(let message) {
      throw TangledError.notFound(message)
    }
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

  private func decode<Value>(
    _ operation: () async throws -> Value
  ) async throws -> Value {
    do {
      return try await operation()
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TangledError {
      throw error
    } catch let error as any XRPCError {
      throw error
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
}

private struct PDSRecordXRPCClient: XRPCCallable {
  let baseURL: URL
  let transport: any HTTPTransport

  func getProxy(nsid _: String) -> String? {
    nil
  }

  func response(_ components: XRPCRequestComponents) async throws -> Data {
    guard components.method == .get else {
      throw TangledError.invalidRequest("PDS record reads support XRPC queries only")
    }
    let endpoint =
      baseURL
      .appendingPathComponent("xrpc", isDirectory: true)
      .appendingPathComponent(components.nsId, isDirectory: false)
    guard var urlComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw TangledError.invalidRequest("invalid PDS endpoint")
    }
    urlComponents.percentEncodedQueryItems = components.queryItems
    guard let url = urlComponents.url else {
      throw TangledError.invalidRequest("invalid PDS request for \(components.nsId)")
    }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = components.method.rawValue
    for field in components.headers {
      request.addValue(field.value, forHTTPHeaderField: field.name.rawName)
    }

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
    return data
  }

  private func mapError(data: Data, response: HTTPURLResponse) -> any Error {
    let failure = try? JSONDecoder().decode(PDSRecordFailure.self, from: data)
    let message = failure?.message ?? failure?.error
    if response.statusCode == 400 || response.statusCode == 404,
      let code = failure?.error,
      !code.isEmpty
    {
      return UnExpectedError(error: code, message: failure?.message)
    }
    switch response.statusCode {
    case 400:
      return TangledError.invalidRequest(message)
    case 401, 403:
      return TangledError.unauthorized
    case 404:
      return TangledError.notFound(message)
    case 429:
      return TangledError.rateLimited(
        retryAfter: RetryAfterHeader.parse(response.value(forHTTPHeaderField: "Retry-After")),
        message: message
      )
    case 502:
      return TangledError.serviceUnavailable(message)
    case 503:
      return TangledError.serviceUnavailable(message)
    default:
      return TangledError.serverStatus(response.statusCode, message)
    }
  }
}

private struct PDSRecordFailure: Decodable {
  let error: String?
  let message: String?
}
