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
    let data = try await send(
      knot: knot,
      nsid: Sh.Tangled.RepoMergeCheck.id,
      body: input,
      authorization: nil
    )
    let output: Sh.Tangled.RepoMergeCheck_Output = try decode(data)
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
    _ = try await send(
      knot: knot,
      nsid: Sh.Tangled.RepoMerge.id,
      body: input,
      authorization: token
    )
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

extension KnotClient {
  fileprivate func send<Body: Encodable>(
    knot: String,
    nsid: String,
    body: Body,
    authorization: String?
  ) async throws -> Data {
    let baseURL = try knotBaseURL(knot)
    let endpoint =
      baseURL
      .appendingPathComponent("xrpc", isDirectory: true)
      .appendingPathComponent(nsid, isDirectory: false)
    var request = URLRequest(url: endpoint, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let authorization {
      request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    request.httpBody = try encoder.encode(body)

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.send(request)
    } catch let error as TangledError {
      throw error
    } catch let error as URLError {
      throw TangledError.network(error)
    } catch {
      throw TangledError.transport(String(describing: error))
    }
    guard (200 ... 299).contains(response.statusCode) else {
      let failure = try? JSONDecoder().decode(KnotFailure.self, from: data)
      let message = failure?.message ?? failure?.error
      switch response.statusCode {
      case 401, 403:
        throw TangledError.unauthorized
      case 404:
        throw TangledError.notFound(message)
      case 409:
        throw TangledError.invalidRequest(message ?? "merge conflict")
      case 429:
        throw TangledError.rateLimited(retryAfter: nil, message: message)
      default:
        throw TangledError.serverStatus(response.statusCode, message)
      }
    }
    return data
  }

  fileprivate func knotBaseURL(_ value: String) throws -> URL {
    let rawValue = value.contains("://") ? value : "https://\(value)"
    guard let url = URL(string: rawValue),
      url.scheme?.lowercased() == "https",
      url.host != nil
    else {
      throw TangledError.invalidRequest("invalid Knot endpoint: \(value)")
    }
    return url
  }

  fileprivate func decode<Value: Decodable>(_ data: Data) throws -> Value {
    do {
      return try JSONDecoder().decode(Value.self, from: data)
    } catch {
      throw TangledError.decoding(error)
    }
  }
}

private struct KnotFailure: Decodable {
  let error: String?
  let message: String?
}
