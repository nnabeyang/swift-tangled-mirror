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
    guard let document = try await resolver.resolve(did: target.ownerDID) else {
      throw TangledError.handleNotResolved(
        "DID document not found: \(target.ownerDID.rawValue)"
      )
    }
    guard document.did.typed == target.ownerDID else {
      throw TangledError.upstreamFailed(
        "DID document does not match \(target.ownerDID.rawValue)"
      )
    }
    let pdsURL: URL
    do {
      pdsURL = try document.pdsUrl
    } catch {
      throw TangledError.handleNotResolved(
        "PDS endpoint not found: \(target.ownerDID.rawValue)"
      )
    }

    let endpoint =
      pdsURL
      .appendingPathComponent("xrpc", isDirectory: true)
      .appendingPathComponent(Com.Atproto.RepoGetRecord.id, isDirectory: false)
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw TangledError.invalidRequest("invalid PDS endpoint")
    }
    components.queryItems = [
      URLQueryItem(name: "repo", value: target.ownerDID.rawValue),
      URLQueryItem(name: "collection", value: target.collection.rawValue),
      URLQueryItem(name: "rkey", value: target.rkey.rawValue),
    ]
    guard let url = components.url else {
      throw TangledError.invalidRequest("invalid PDS getRecord request")
    }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.send(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TangledError {
      throw error
    } catch let error as URLError {
      throw TangledError.network(error)
    } catch {
      throw TangledError.transport(String(describing: error))
    }
    guard (200 ... 299).contains(response.statusCode) else {
      throw mapError(data: data, response: response)
    }

    let output: Com.Atproto.RepoGetRecord_Output
    do {
      let decoder = JSONDecoder()
      decoder.userInfo[.atprotoLexiconDecodingMode] = LexiconDecodingMode.permissive
      output = try decoder.decode(Com.Atproto.RepoGetRecord_Output.self, from: data)
    } catch {
      throw TangledError.decoding(error)
    }
    let returnedURI: ATURI
    do {
      returnedURI = try ATURI(string: output.uri.rawValue)
    } catch {
      throw TangledError.upstreamFailed("PDS returned an invalid record URI")
    }
    guard returnedURI.authority == target.uri.authority,
      returnedURI.collection == target.uri.collection,
      returnedURI.rkey == target.uri.rkey,
      returnedURI.fragment == nil
    else {
      throw TangledError.upstreamFailed(
        "PDS returned \(output.uri.rawValue), expected \(target.uri.rawValue)"
      )
    }
    let returnedType = try TangledRecordDecoder.recordType(of: output.value)
    guard returnedType == collection else {
      throw TangledError.upstreamFailed(
        "PDS returned record type \(returnedType), expected \(collection)"
      )
    }
    return output
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
      return .upstreamFailed(message)
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
