import Foundation
import SwiftAtproto
import TangledLexicons

public struct SpindleClient: XRPCCallable, XRPCSubscriptionCallable, Sendable {
  // Keep replay bounded while allowing completed pipelines to deliver thousands of
  // retained log events before a terminal consumer catches up. This is a client
  // limit, not a Spindle protocol guarantee.
  static let pipelineLogBufferCapacity = 4_096

  public let baseURL: URL
  public let retryPolicy: BobbinRetryPolicy
  public let subscriptionTransport: any XRPCSubscriptionTransport
  public let subscriptionConfiguration = XRPCSubscriptionConfiguration(
    maximumFrameBytes: 2 * 1_024 * 1_024,
    bufferCapacity: Self.pipelineLogBufferCapacity
  )

  private let queryClient: BobbinClient
  package let transport: any HTTPTransport

  public init(
    baseURL: URL,
    transport: any HTTPTransport = URLSessionTransport(),
    retryPolicy: BobbinRetryPolicy = .default
  ) {
    self.baseURL = baseURL
    self.retryPolicy = retryPolicy
    self.transport = transport
    self.subscriptionTransport = WebSocketXRPCSubscriptionTransport()
    self.queryClient = BobbinClient(
      baseURL: baseURL,
      transport: transport,
      retryPolicy: retryPolicy
    )
  }

  public init(
    spindle: String,
    transport: any HTTPTransport = URLSessionTransport(),
    retryPolicy: BobbinRetryPolicy = .default
  ) throws {
    let value = spindle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      throw TangledError.invalidRequest("spindle must not be empty")
    }

    let urlString = value.contains("://") ? value : "https://\(value)"
    guard
      let components = URLComponents(string: urlString),
      let scheme = components.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      components.host != nil,
      components.query == nil,
      components.fragment == nil,
      let url = components.url
    else {
      throw TangledError.invalidRequest("spindle must be a hostname or HTTP(S) URL")
    }

    self.init(baseURL: url, transport: transport, retryPolicy: retryPolicy)
  }

  init(
    baseURL: URL,
    transport: any HTTPTransport,
    subscriptionTransport: any XRPCSubscriptionTransport,
    retryPolicy: BobbinRetryPolicy = .default
  ) {
    self.baseURL = baseURL
    self.retryPolicy = retryPolicy
    self.transport = transport
    self.subscriptionTransport = subscriptionTransport
    self.queryClient = BobbinClient(
      baseURL: baseURL,
      transport: transport,
      retryPolicy: retryPolicy
    )
  }

  public func getProxy(nsid: String) -> String? {
    nil
  }

  public func response(_ requestComponents: XRPCRequestComponents) async throws -> Data {
    try await queryClient.response(requestComponents)
  }

  public func prepareSubscriptionRequest(
    _ components: XRPCSubscriptionRequestComponents
  ) async throws -> XRPCWebSocketRequest {
    var urlComponents = URLComponents(
      url: baseURL.appending(path: "xrpc/\(components.nsId)"),
      resolvingAgainstBaseURL: false
    )
    switch urlComponents?.scheme?.lowercased() {
    case "https":
      urlComponents?.scheme = "wss"
    case "http":
      urlComponents?.scheme = "ws"
    default:
      throw TangledError.invalidRequest("Spindle subscription requires an HTTP(S) URL")
    }
    urlComponents?.percentEncodedQueryItems = components.queryItems
    guard let url = urlComponents?.url else {
      throw TangledError.invalidRequest("could not construct the Spindle subscription URL")
    }
    return XRPCWebSocketRequest(url: url, headers: components.headers)
  }
}
