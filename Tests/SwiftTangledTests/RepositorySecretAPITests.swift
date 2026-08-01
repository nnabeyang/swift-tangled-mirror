import Foundation
import SwiftAtproto
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@testable import SwiftTangled

private let apiSecretRepositoryURI = "at://did:plc:owner/sh.tangled.repo/core"
private let apiSecretMetadata = RepositorySecret(
  repositoryURI: apiSecretRepositoryURI,
  key: "TOKEN",
  createdAt: FormatString(rawValue: "2026-08-01T00:00:00Z"),
  createdByDID: "did:plc:owner"
)

@Suite struct RepositorySecretAPITests {
  @Test func listUsesAuthenticatedSpindleEndpointAndMapsMetadata() async throws {
    let transport = SecretHTTPTransport(
      responseBody: #"{"secrets":[{"repo":"at://did:plc:owner/sh.tangled.repo/core","key":"TOKEN","createdAt":"2026-08-01T00:00:00Z","createdBy":"did:plc:owner"}]}"#
    )
    let client = try SpindleClient(spindle: "spindle.example", transport: transport)

    let secrets = try await client.repositorySecrets(
      repositoryURI: apiSecretRepositoryURI,
      token: "service-token"
    )

    #expect(secrets == [apiSecretMetadata])
    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/xrpc/sh.tangled.repo.listSecrets")
    #expect(
      request.url?.query == "repo=at%3A%2F%2Fdid%3Aplc%3Aowner%2Fsh.tangled.repo%2Fcore"
    )
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer service-token")
  }

  @Test func addAndRemoveUseGeneratedValidatedInputs() async throws {
    let transport = SecretHTTPTransport(responseBody: "{}")
    let client = try SpindleClient(spindle: "spindle.example", transport: transport)

    try await client.addRepositorySecret(
      repositoryURI: apiSecretRepositoryURI,
      key: "TOKEN",
      value: "secret-value",
      token: "add-token"
    )
    try await client.removeRepositorySecret(
      repositoryURI: apiSecretRepositoryURI,
      key: "TOKEN",
      token: "remove-token"
    )

    let requests = await transport.requests
    #expect(
      requests.map(\.url?.path) == [
        "/xrpc/sh.tangled.repo.addSecret",
        "/xrpc/sh.tangled.repo.removeSecret",
      ])
    let addBody = try #require(requests[0].httpBody).utf8String
    #expect(addBody.contains(#""key":"TOKEN""#))
    #expect(addBody.contains(#""value":"secret-value""#))
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer add-token")
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer remove-token")
  }

  @Test func nullSecretListFromSpindleIsTreatedAsEmpty() async throws {
    let transport = SecretHTTPTransport(responseBody: #"{"secrets":null}"#)
    let client = try SpindleClient(spindle: "spindle.example", transport: transport)

    let secrets = try await client.repositorySecrets(
      repositoryURI: apiSecretRepositoryURI,
      token: "service-token"
    )

    #expect(secrets.isEmpty)
  }

  @Test func invalidKeyAndValueFailBeforeTransport() async throws {
    let transport = SecretHTTPTransport(responseBody: "{}")
    let client = try SpindleClient(spindle: "spindle.example", transport: transport)

    await #expect(throws: (any Error).self) {
      try await client.addRepositorySecret(
        repositoryURI: apiSecretRepositoryURI,
        key: "TOKEN",
        value: String(repeating: "v", count: 201),
        token: "token"
      )
    }
    await #expect(throws: (any Error).self) {
      try await client.removeRepositorySecret(
        repositoryURI: apiSecretRepositoryURI,
        key: "",
        token: "token"
      )
    }
    #expect(await transport.requests.isEmpty)
  }
}

private actor SecretHTTPTransport: HTTPTransport {
  private(set) var requests: [URLRequest] = []
  private let responseBody: String

  init(responseBody: String) {
    self.responseBody = responseBody
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(responseBody.utf8), response)
  }
}

private extension Data {
  var utf8String: String { String(decoding: self, as: UTF8.self) }
}
