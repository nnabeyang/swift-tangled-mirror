import Foundation
import SwiftAtproto
import TangledLexicons
import Testing

@testable import SwiftTangled

@Suite struct GitAuthenticationServiceTests {
  @Test func buildsCanonicalHTTPSGitTarget() async throws {
    let service = GitAuthenticationService { _ in sampleRepository() }

    let target = try await service.target(for: "git@knot.example:did:plc:repo")

    #expect(target.repositoryURI == "at://did:plc:owner/sh.tangled.repo/example")
    #expect(target.repositoryDID == "did:plc:repo")
    #expect(target.knot == "knot.example")
    #expect(target.url == "https://knot.example/did:plc:repo/")
  }

  @Test func rejectsInvalidKnotAndMissingRepositoryDID() async {
    let invalidKnot = GitAuthenticationService { _ in sampleRepository(knot: "http://knot.example") }
    await #expect(throws: TangledError.self) { try await invalidKnot.target(for: "repository") }

    let missingDID = GitAuthenticationService { _ in sampleRepository(repositoryDID: nil) }
    await #expect(throws: TangledError.self) { try await missingDID.target(for: "repository") }
  }

  @Test func returnsShortLivedServiceAuthOnlyForExactHTTPSRepository() async throws {
    let service = GitAuthenticationService { _ in sampleRepository() }
    let target = try await service.target(for: "repository")
    let client = PDSClient(
      client: PushServiceAuthMock(),
      repoDID: "did:plc:alice",
      authorizedScopes: ["rpc:sh.tangled.repo.push?aud=*"]
    )

    let credential = try await service.credential(
      for: GitCredentialRequest(
        protocolName: "https", host: "knot.example", path: "did:plc:repo"),
      target: target,
      accountHandle: "alice.test",
      pdsClient: client
    )
    #expect(credential == GitCredential(username: "alice.test", password: "service-token"))

    let encodedCredential = try await service.credential(
      for: GitCredentialRequest(
        protocolName: "https", host: "knot.example", path: "did%3Aplc%3Arepo"),
      target: target,
      accountHandle: "alice.test",
      pdsClient: client
    )
    #expect(encodedCredential == credential)

    await #expect(throws: TangledError.self) {
      try await service.credential(
        for: GitCredentialRequest(
          protocolName: "https", host: "other.example", path: "did:plc:repo"),
        target: target,
        accountHandle: "alice.test",
        pdsClient: client
      )
    }
  }
}

private struct PushServiceAuthMock: XRPCCallable {
  func getProxy(nsid _: String) -> String? { nil }

  func response(_ components: XRPCRequestComponents) async throws -> Data {
    guard components.nsId == "com.atproto.server.getServiceAuth" else {
      throw TangledError.invalidRequest("unexpected request")
    }
    return Data(#"{"token":"service-token"}"#.utf8)
  }
}

private func sampleRepository(
  knot: String = "knot.example",
  repositoryDID: String? = "did:plc:repo"
) -> TangledRecord<Repository> {
  TangledRecord(
    uri: "at://did:plc:owner/sh.tangled.repo/example",
    cid: "cid",
    value: Repository(
      name: "example",
      knot: knot,
      repoDID: repositoryDID,
      createdAt: FormatString(rawValue: "2026-08-16T00:00:00Z")
    )
  )
}
