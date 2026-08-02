import Foundation
import SwiftAtproto
import TangledLexicons

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct HTTPXRPCClient: XRPCCallable, Sendable {
  let baseURL: URL
  let transport: any HTTPTransport
  var bearerToken: String?
  var accept: String?
  /// Fallback message used when a 409 response has no error body. Callers that
  /// operate on a specific semantic domain (Knot merges, etc.) can supply a
  /// more descriptive string than the generic default.
  var conflictMessage: String

  init(
    baseURL: URL,
    transport: any HTTPTransport,
    bearerToken: String? = nil,
    accept: String? = nil,
    conflictMessage: String = "conflict"
  ) {
    self.baseURL = baseURL
    self.transport = transport
    self.bearerToken = bearerToken
    self.accept = accept
    self.conflictMessage = conflictMessage
  }

  func getProxy(nsid _: String) -> String? {
    nil
  }

  func response(_ components: XRPCRequestComponents) async throws -> Data {
    let request = try request(for: components)
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
    return data
  }

  func request(
    for components: XRPCRequestComponents
  ) throws(TangledError) -> URLRequest {
    let endpoint =
      baseURL
      .appendingPathComponent("xrpc", isDirectory: true)
      .appendingPathComponent(components.nsId, isDirectory: false)
    guard var urlComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw TangledError.invalidRequest("invalid XRPC endpoint")
    }
    if !components.queryItems.isEmpty {
      urlComponents.percentEncodedQueryItems = components.queryItems
    }
    guard let url = urlComponents.url else {
      throw TangledError.invalidRequest("invalid XRPC request for \(components.nsId)")
    }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = components.method.rawValue
    request.httpBody = components.body
    for field in components.headers where field.name != .accept {
      request.addValue(field.value, forHTTPHeaderField: field.name.rawName)
    }
    request.setValue(accept ?? "application/json", forHTTPHeaderField: "Accept")
    if let bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private func mapError(data: Data, response: HTTPURLResponse) -> any Error {
    let failure = try? JSONDecoder().decode(XRPCFailureEnvelope.self, from: data)
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
    case 401:
      return TangledError.unauthorized
    case 403:
      return TangledError.forbidden(message)
    case 404:
      return TangledError.notFound(message)
    case 409:
      return TangledError.invalidRequest(message ?? conflictMessage)
    case 429:
      return TangledError.rateLimited(
        retryAfter: RetryAfterHeader.parse(response.value(forHTTPHeaderField: "Retry-After")),
        message: message
      )
    case 502, 503, 504:
      return TangledError.serviceUnavailable(message)
    default:
      return TangledError.serverStatus(response.statusCode, message)
    }
  }
}

private struct XRPCFailureEnvelope: Decodable {
  let error: String?
  let message: String?
}
