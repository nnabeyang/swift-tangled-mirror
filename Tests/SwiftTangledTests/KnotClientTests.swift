import Foundation
import SwiftTangled
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct KnotClientTests {
  @Test func mergeCheckUsesKnotProcedureAndMapsConflicts() async throws {
    let transport = KnotTransport(
      statusCode: 200,
      body: Data(
        """
        {"is_conflicted":true,"conflicts":[{"filename":"Sources/App.swift","reason":"content"}],"message":"resolve conflicts"}
        """.utf8
      )
    )
    let result = try await KnotClient(transport: transport).mergeCheck(
      knot: "knot.example",
      ownerDID: "did:plc:owner",
      repositoryName: "core",
      repositoryDID: "did:plc:repository",
      branch: "main",
      patch: "patch"
    )

    #expect(result.isConflicted)
    #expect(result.conflicts == [.init(filename: "Sources/App.swift", reason: "content")])
    let request = try #require(await transport.request())
    #expect(request.url?.absoluteString == "https://knot.example/xrpc/sh.tangled.repo.mergeCheck")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let body = try #require(request.httpBody)
    #expect(String(decoding: body, as: UTF8.self).contains("\"repo\":\"did:plc:repository\""))
  }

  @Test func mergeSendsServiceToken() async throws {
    let transport = KnotTransport(statusCode: 200, body: Data("{}".utf8))
    try await KnotClient(transport: transport).merge(
      knot: "https://knot.example",
      token: "service-token",
      ownerDID: "did:plc:owner",
      repositoryName: "core",
      repositoryDID: "did:plc:repository",
      branch: "main",
      patch: "patch",
      commitMessage: "Merge title",
      commitBody: "Merge body"
    )

    let request = try #require(await transport.request())
    #expect(request.url?.absoluteString == "https://knot.example/xrpc/sh.tangled.repo.merge")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer service-token")
  }
}

private actor KnotTransport: HTTPTransport {
  private let statusCode: Int
  private let body: Data
  private var recordedRequest: URLRequest?

  init(statusCode: Int, body: Data) {
    self.statusCode = statusCode
    self.body = body
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    recordedRequest = request
    return (
      body,
      HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: [:]
      )!
    )
  }

  func request() -> URLRequest? {
    recordedRequest
  }
}
