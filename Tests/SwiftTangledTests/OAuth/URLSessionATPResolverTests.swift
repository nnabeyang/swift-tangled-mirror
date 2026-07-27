import Foundation
import SwiftAtproto
import SwiftTangled
import TangledLexicons
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite(.serialized) struct URLSessionATPResolverTests {
  @Test func handleResolutionFallsBackToXRPCService() async throws {
    ResolverURLProtocol.reset()
    let resolver = makeResolver()

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

  @Test func malformedFallbackDIDMapsToDecodingError() async {
    ResolverURLProtocol.reset()
    let resolver = makeResolver()

    do {
      _ = try await resolver.resolve(handle: Handle(string: "malformed.example"))
      Issue.record("Expected decoding error")
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func handleNotFoundFromFallbackReturnsNil() async throws {
    ResolverURLProtocol.reset()
    let resolver = makeResolver()

    let did = try await resolver.resolve(handle: Handle(string: "missing.example"))

    #expect(did == nil)
    let requests = ResolverURLProtocol.recordedRequests()
    #expect(requests.count == 2)
    #expect(
      requests[1].url?.absoluteString
        == "https://resolver.example/xrpc/com.atproto.identity.resolveHandle?handle=missing.example"
    )
  }

  @Test func unrelatedInvalidRequestFromFallbackPropagates() async {
    ResolverURLProtocol.reset()
    let resolver = makeResolver()

    do {
      _ = try await resolver.resolve(handle: Handle(string: "bogus.example"))
      Issue.record("Expected generated XRPC error")
    } catch Com.Atproto.IdentityResolveHandle.Error.unexpected(let code, let message) {
      #expect(code == "InvalidRequest")
      #expect(message == "bogus")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  private func makeResolver() -> URLSessionATPResolver {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ResolverURLProtocol.self]
    return URLSessionATPResolver(
      session: URLSession(configuration: configuration),
      plcDirectory: URL(string: "https://plc.example")!,
      handleResolver: URL(string: "https://resolver.example")!
    )
  }
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
    let handle = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first { $0.name == "handle" }?
      .value
    let statusCode: Int
    let body: Data
    if !isFallback {
      statusCode = 500
      body = Data()
    } else if handle == "malformed.example" {
      statusCode = 200
      body = Data(#"{"did":"not-a-did"}"#.utf8)
    } else if handle == "missing.example" {
      statusCode = 400
      body = Data(
        #"{"error":"HandleNotFound","message":"handle missing.example not found"}"#.utf8
      )
    } else if handle == "bogus.example" {
      statusCode = 400
      body = Data(#"{"error":"InvalidRequest","message":"bogus"}"#.utf8)
    } else {
      statusCode = 200
      body = Data(#"{"did":"did:plc:resolved"}"#.utf8)
    }
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
