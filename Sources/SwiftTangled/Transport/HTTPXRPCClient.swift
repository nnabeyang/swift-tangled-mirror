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

  func request(for components: XRPCRequestComponents) throws -> URLRequest {
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
    for field in components.headers {
      request.addValue(field.value, forHTTPHeaderField: field.name.rawName)
    }
    if let accept {
      request.setValue(accept, forHTTPHeaderField: "Accept")
    } else if request.value(forHTTPHeaderField: "Accept") != "*/*" {
      request.setValue("application/json", forHTTPHeaderField: "Accept")
    }
    if let bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private func mapError(data: Data, response: HTTPURLResponse) -> TangledError {
    let failure = try? JSONDecoder().decode(XRPCFailureEnvelope.self, from: data)
    let message = failure?.message ?? failure?.error
    switch response.statusCode {
    case 400:
      return .invalidRequest(message)
    case 401:
      return .unauthorized
    case 403:
      return .forbidden(message)
    case 404:
      return .notFound(message)
    case 409:
      return .invalidRequest(message ?? conflictMessage)
    case 429:
      return .rateLimited(
        retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init),
        message: message
      )
    case 502, 503, 504:
      return .serviceUnavailable(message)
    default:
      return .serverStatus(response.statusCode, message)
    }
  }
}

private struct XRPCFailureEnvelope: Decodable {
  let error: String?
  let message: String?
}
