import Foundation
import SwiftAtproto
import TangledLexicons

public struct SpindleClient: XRPCCallable, Sendable {
  public let baseURL: URL
  public let retryPolicy: BobbinRetryPolicy

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

  public func getProxy(nsid: String) -> String? {
    nil
  }

  public func response(_ requestComponents: XRPCRequestComponents) async throws -> Data {
    try await queryClient.response(requestComponents)
  }
}
