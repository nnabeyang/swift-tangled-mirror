import Foundation
import SwiftAtproto
import SwiftTangled
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test func handleResolutionFallsBackToXRPCService() async throws {
  ResolverURLProtocol.reset()
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ResolverURLProtocol.self]
  let resolver = URLSessionATPResolver(
    session: URLSession(configuration: configuration),
    plcDirectory: URL(string: "https://plc.example")!,
    handleResolver: URL(string: "https://resolver.example")!
  )

  let did = try await resolver.resolve(handle: Handle(string: "alice.example"))

  #expect(did?.rawValue == "did:plc:resolved")
  let requests = ResolverURLProtocol.recordedRequests()
  #expect(requests.count == 2)
  #expect(requests[0].url?.absoluteString == "https://alice.example/.well-known/atproto-did")
  #expect(
    requests[1].url?.absoluteString
      == "https://resolver.example/xrpc/com.atproto.identity.resolveHandle?handle=alice.example"
  )
}

private final class ResolverURLProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requests: [URLRequest] = []

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.lock.lock()
    Self.requests.append(request)
    Self.lock.unlock()

    let isFallback = request.url?.host == "resolver.example"
    let statusCode = isFallback ? 200 : 500
    let body = isFallback ? Data(#"{"did":"did:plc:resolved"}"#.utf8) : Data()
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func reset() {
    lock.lock()
    requests = []
    lock.unlock()
  }

  static func recordedRequests() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}
