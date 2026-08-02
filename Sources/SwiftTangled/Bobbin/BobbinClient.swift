import Foundation
import SwiftAtproto
import TangledLexicons

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct BobbinRetryPolicy: Equatable, Sendable {
  public let maxAttempts: Int
  public let baseDelay: TimeInterval
  public let maxRetryAfter: TimeInterval

  public init(
    maxAttempts: Int = 3,
    baseDelay: TimeInterval = 0.25,
    maxRetryAfter: TimeInterval = 60
  ) {
    self.maxAttempts = max(1, maxAttempts)
    self.baseDelay = max(0, baseDelay)
    self.maxRetryAfter = max(0, maxRetryAfter)
  }

  public static let `default` = BobbinRetryPolicy()
}

protocol BobbinSleeping: Sendable {
  func sleep(for delay: TimeInterval) async throws
}

private struct TaskBobbinSleeper: BobbinSleeping {
  func sleep(for delay: TimeInterval) async throws {
    guard delay > 0 else { return }
    try await Task.sleep(for: .seconds(delay))
  }
}

public struct BobbinClient: XRPCCallable, Sendable {
  public static let defaultBaseURL = URL(string: "https://api.tangled.org")!
  private static let rateLimitFallbackBaseDelay: TimeInterval = 2

  public let baseURL: URL
  public let retryPolicy: BobbinRetryPolicy

  private let transport: any HTTPTransport
  private let sleeper: any BobbinSleeping
  private let now: @Sendable () -> Date

  public init(
    baseURL: URL = BobbinClient.defaultBaseURL,
    transport: any HTTPTransport = URLSessionTransport(),
    retryPolicy: BobbinRetryPolicy = .default
  ) {
    self.init(
      baseURL: baseURL,
      transport: transport,
      retryPolicy: retryPolicy,
      sleeper: TaskBobbinSleeper(),
      now: Date.init
    )
  }

  init(
    baseURL: URL,
    transport: any HTTPTransport,
    retryPolicy: BobbinRetryPolicy,
    sleeper: any BobbinSleeping,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.baseURL = baseURL
    self.transport = transport
    self.retryPolicy = retryPolicy
    self.sleeper = sleeper
    self.now = now
  }

  public func coverage() async throws -> BobbinCoverage {
    do {
      return try await get(nsid: "sh.tangled.bobbin.getCoverage")
    } catch let error as UnExpectedError {
      switch error.error {
      case "InvalidRequest":
        throw TangledError.invalidRequest(error.message)
      case "RecordNotFound":
        throw TangledError.notFound(error.message)
      default:
        throw error
      }
    }
  }

  public func getProxy(nsid: String) -> String? {
    nil
  }

  public func response(_ requestComponents: XRPCRequestComponents) async throws -> Data {
    try await responseWithMetadata(requestComponents).0
  }

  func responseWithMetadata(
    _ requestComponents: XRPCRequestComponents
  ) async throws -> (Data, HTTPURLResponse) {
    try await responseResult(for: request(for: requestComponents))
  }

  func streamingResponseWithMetadata(
    _ requestComponents: XRPCRequestComponents
  ) async throws -> (HTTPBodyStream, HTTPURLResponse) {
    try await streamingResponseResult(for: request(for: requestComponents))
  }

  func get<Response: Decodable & Sendable>(
    nsid: String,
    queryItems: [URLQueryItem] = []
  ) async throws -> Response {
    let endpoint =
      baseURL
      .appendingPathComponent("xrpc", isDirectory: true)
      .appendingPathComponent(nsid, isDirectory: false)
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw TangledError.invalidRequest("Invalid Bobbin base URL: \(baseURL.absoluteString)")
    }
    if !queryItems.isEmpty {
      components.queryItems = queryItems
    }
    guard let url = components.url else {
      throw TangledError.invalidRequest("Invalid Bobbin request URL for \(nsid)")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let data = try await responseData(for: request)
    do {
      let decoder = JSONDecoder()
      decoder.userInfo[.atprotoLexiconDecodingMode] = LexiconDecodingMode.permissive
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw TangledError.decoding(error)
    }
  }

  private func responseData(for request: URLRequest) async throws -> Data {
    try await responseResult(for: request).0
  }

  private func request(for requestComponents: XRPCRequestComponents) throws -> URLRequest {
    guard requestComponents.method == .get else {
      throw TangledError.invalidRequest("BobbinClient supports XRPC queries only")
    }

    let endpoint =
      baseURL
      .appendingPathComponent("xrpc", isDirectory: true)
      .appendingPathComponent(requestComponents.nsId, isDirectory: false)
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw TangledError.invalidRequest("Invalid Bobbin base URL: \(baseURL.absoluteString)")
    }
    components.percentEncodedQueryItems = requestComponents.queryItems
    guard let url = components.url else {
      throw TangledError.invalidRequest("Invalid Bobbin request URL for \(requestComponents.nsId)")
    }

    var request = URLRequest(url: url)
    request.httpMethod = requestComponents.method.rawValue
    for field in requestComponents.headers {
      request.addValue(field.value, forHTTPHeaderField: field.name.rawName)
    }
    if request.value(forHTTPHeaderField: "Accept") != "*/*" {
      request.setValue("application/json", forHTTPHeaderField: "Accept")
    }
    return request
  }

  private func responseResult(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    var attempt = 1
    while true {
      do {
        let (data, response) = try await transport.send(request)
        if (200 ... 299).contains(response.statusCode) {
          return (data, response)
        }

        let retryAfter = RetryAfterHeader.parse(
          response.value(forHTTPHeaderField: "Retry-After"),
          now: now
        )
        if shouldRetry(statusCode: response.statusCode), attempt < retryPolicy.maxAttempts {
          try await sleeper.sleep(
            for: retryDelay(
              attempt: attempt,
              statusCode: response.statusCode,
              retryAfter: retryAfter
            )
          )
          attempt += 1
          continue
        }
        throw mapHTTPError(data: data, response: response, retryAfter: retryAfter)
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as UnExpectedError {
        throw error
      } catch let error as TangledError {
        throw error
      } catch let error as URLError {
        if Task.isCancelled {
          throw CancellationError()
        }
        if shouldRetry(error), attempt < retryPolicy.maxAttempts {
          try await sleeper.sleep(for: retryDelay(attempt: attempt, retryAfter: nil))
          attempt += 1
          continue
        }
        throw TangledError.network(error)
      } catch {
        throw TangledError.transport(String(describing: error))
      }
    }
  }

  private func streamingResponseResult(
    for request: URLRequest
  ) async throws -> (HTTPBodyStream, HTTPURLResponse) {
    var attempt = 1
    while true {
      do {
        let (body, response) = try await transport.sendStreaming(request)
        if (200 ... 299).contains(response.statusCode) {
          return (body, response)
        }

        let data = await errorBody(from: body, maximumBytes: 64 * 1024)
        let retryAfter = RetryAfterHeader.parse(
          response.value(forHTTPHeaderField: "Retry-After"),
          now: now
        )
        if shouldRetry(statusCode: response.statusCode), attempt < retryPolicy.maxAttempts {
          try await sleeper.sleep(
            for: retryDelay(
              attempt: attempt,
              statusCode: response.statusCode,
              retryAfter: retryAfter
            )
          )
          attempt += 1
          continue
        }
        throw mapHTTPError(data: data, response: response, retryAfter: retryAfter)
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as UnExpectedError {
        throw error
      } catch let error as TangledError {
        throw error
      } catch let error as URLError {
        if Task.isCancelled {
          throw CancellationError()
        }
        if shouldRetry(error), attempt < retryPolicy.maxAttempts {
          try await sleeper.sleep(for: retryDelay(attempt: attempt, retryAfter: nil))
          attempt += 1
          continue
        }
        throw TangledError.network(error)
      } catch {
        throw TangledError.transport(String(describing: error))
      }
    }
  }

  private func errorBody(from body: HTTPBodyStream, maximumBytes: Int) async -> Data {
    var result = Data()
    do {
      for try await chunk in body {
        let remaining = maximumBytes - result.count
        guard remaining > 0 else {
          body.cancel()
          break
        }
        result.append(chunk.prefix(remaining))
        if chunk.count >= remaining {
          body.cancel()
          break
        }
      }
    } catch {
      body.cancel()
    }
    return result
  }

  private func shouldRetry(statusCode: Int) -> Bool {
    statusCode == 429 || statusCode == 502 || statusCode == 503 || statusCode == 504
  }

  private func shouldRetry(_ error: URLError) -> Bool {
    switch error.code {
    case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
      .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable:
      true
    default:
      false
    }
  }

  private func retryDelay(
    attempt: Int,
    statusCode: Int? = nil,
    retryAfter: TimeInterval?
  ) -> TimeInterval {
    if let retryAfter {
      return min(max(0, retryAfter), retryPolicy.maxRetryAfter)
    }
    let baseDelay =
      statusCode == 429 ? Self.rateLimitFallbackBaseDelay : retryPolicy.baseDelay
    return baseDelay * pow(2, Double(attempt - 1))
  }

  private func mapHTTPError(
    data: Data,
    response: HTTPURLResponse,
    retryAfter: TimeInterval?
  ) -> any Error {
    let body = try? JSONDecoder().decode(BobbinErrorEnvelope.self, from: data)
    let message = body?.message ?? body?.error
    if response.statusCode == 400 || response.statusCode == 404,
      let code = body?.error,
      !code.isEmpty
    {
      return UnExpectedError(error: code, message: body?.message)
    }
    switch response.statusCode {
    case 400:
      return TangledError.invalidRequest(message)
    case 401:
      return TangledError.unauthorized
    case 404:
      return TangledError.notFound(message)
    case 429:
      return TangledError.rateLimited(retryAfter: retryAfter, message: message)
    case 502:
      return TangledError.upstreamFailed(message)
    case 503:
      return TangledError.serviceUnavailable(message)
    default:
      return TangledError.serverStatus(response.statusCode, message)
    }
  }
}

private struct BobbinErrorEnvelope: Decodable {
  let error: String?
  let message: String?
}
