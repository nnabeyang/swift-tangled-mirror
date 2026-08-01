import Foundation
import SwiftAtproto
import TangledLexicons
import Testing

@testable import SwiftTangled

@Suite struct RepositorySecretServiceTests {
  @Test func listsOnlySecretMetadataWithListServiceAuthentication() async throws {
    let recorder = SecretRecorder(secrets: [secretMetadata])
    let service = makeSecretService(recorder: recorder)

    let result = try await service.secrets(
      repository: "alice.example/core",
      spindle: "spindle.example",
      pdsClient: makeSecretPDSClient()
    )

    #expect(result.repositoryURI == secretRepositoryURI)
    #expect(result.spindle == "https://spindle.example")
    #expect(result.secrets == [secretMetadata])
    #expect(await recorder.listCount == 1)
  }

  @Test func existingAdditionDoesNotAcceptOrWriteAValue() async throws {
    let recorder = SecretRecorder(secrets: [secretMetadata])
    let service = makeSecretService(recorder: recorder)
    let client = makeSecretPDSClient()
    let plan = try await service.prepareAddition(
      repository: "alice.example/core",
      key: "TOKEN",
      pdsClient: client
    )

    let result = try await service.add(plan, value: "must-not-be-written", pdsClient: client)

    #expect(plan.isPresent)
    #expect(result.outcome == .alreadyPresent)
    #expect(await recorder.addCount == 0)
  }

  @Test func absentRemovalDoesNotWrite() async throws {
    let recorder = SecretRecorder()
    let service = makeSecretService(recorder: recorder)
    let client = makeSecretPDSClient()
    let plan = try await service.prepareRemoval(
      repository: "alice.example/core",
      key: "TOKEN",
      pdsClient: client
    )

    let result = try await service.remove(plan, pdsClient: client)

    #expect(!plan.isPresent)
    #expect(result.outcome == .notPresent)
    #expect(await recorder.removeCount == 0)
  }

  @Test func ambiguousAdditionReturnsUnknownWithoutRetryOrSecret() async throws {
    let secret = "sentinel-secret-value"
    let recorder = SecretRecorder(addError: TangledError.serviceUnavailable(secret))
    let service = makeSecretService(recorder: recorder)
    let client = makeSecretPDSClient()
    let plan = try await service.prepareAddition(
      repository: "alice.example/core",
      key: "TOKEN",
      pdsClient: client
    )

    let result = try await service.add(plan, value: secret, pdsClient: client)

    #expect(result.outcome == .outcomeUnknown)
    #expect(await recorder.addCount == 1)
    #expect(!String(describing: result).contains(secret))
  }

  @Test func nonAmbiguousAdditionErrorRedactsSecret() async throws {
    let secret = "sentinel-secret-value"
    let recorder = SecretRecorder(addError: TangledError.invalidRequest("rejected \(secret)"))
    let service = makeSecretService(recorder: recorder)
    let client = makeSecretPDSClient()
    let plan = try await service.prepareAddition(
      repository: "alice.example/core",
      key: "TOKEN",
      pdsClient: client
    )

    do {
      _ = try await service.add(plan, value: secret, pdsClient: client)
      Issue.record("expected the addition to fail")
    } catch {
      #expect(!String(describing: error).contains(secret))
      #expect(String(describing: error).contains("[REDACTED]"))
    }
  }

  @Test func rejectsInvalidKeyBeforeAuthenticationOrSpindleAccess() async {
    let recorder = SecretRecorder()
    let service = makeSecretService(recorder: recorder)

    await #expect(throws: TangledError.self) {
      _ = try await service.prepareAddition(
        repository: "alice.example/core",
        key: String(repeating: "k", count: 51),
        pdsClient: makeSecretPDSClient()
      )
    }
    #expect(await recorder.listCount == 0)
  }
}

private let secretRepositoryURI = "at://did:plc:owner/sh.tangled.repo/core"
private let secretMetadata = RepositorySecret(
  repositoryURI: secretRepositoryURI,
  key: "TOKEN",
  createdAt: FormatString(rawValue: "2026-08-01T00:00:00Z"),
  createdByDID: "did:plc:owner"
)

private func makeSecretService(recorder: SecretRecorder) -> RepositorySecretService {
  RepositorySecretService(
    dependencies: RepositorySecretDependencies(
      repository: { _ in
        TangledRecord(
          uri: secretRepositoryURI,
          cid: "bafyreisecret",
          value: Repository(
            name: "core",
            knot: "knot.example",
            spindle: "spindle.example",
            repoDID: "did:plc:repository",
            createdAt: FormatString(rawValue: "2026-08-01T00:00:00Z")
          )
        )
      },
      list: { spindle, token, repositoryURI in
        await recorder.list(spindle: spindle, token: token, repositoryURI: repositoryURI)
      },
      add: { spindle, token, repositoryURI, key, value in
        try await recorder.add(
          spindle: spindle,
          token: token,
          repositoryURI: repositoryURI,
          key: key,
          value: value
        )
      },
      remove: { _, _, _, _ in await recorder.remove() },
      validateKey: { repositoryURI, key in
        try validateRepositorySecretKey(repositoryURI: repositoryURI, key: key)
      },
      serviceAudience: { _ in "did:web:spindle.example" }
    )
  )
}

private func makeSecretPDSClient() -> PDSClient {
  PDSClient(
    client: SecretServiceAuthMock(),
    repoDID: "did:plc:owner",
    authorizedScopes: [
      "atproto",
      "rpc:sh.tangled.repo.addSecret?aud=*",
      "rpc:sh.tangled.repo.listSecrets?aud=*",
      "rpc:sh.tangled.repo.removeSecret?aud=*",
    ]
  )
}

private actor SecretRecorder {
  private(set) var listCount = 0
  private(set) var addCount = 0
  private(set) var removeCount = 0
  private let secrets: [RepositorySecret]
  private let addError: (any Error)?

  init(secrets: [RepositorySecret] = [], addError: (any Error)? = nil) {
    self.secrets = secrets
    self.addError = addError
  }

  func list(spindle _: String, token _: String, repositoryURI _: String) -> [RepositorySecret] {
    listCount += 1
    return secrets
  }

  func add(
    spindle _: String,
    token _: String,
    repositoryURI _: String,
    key _: String,
    value _: String
  ) throws {
    addCount += 1
    if let addError { throw addError }
  }

  func remove() { removeCount += 1 }
}

private actor SecretServiceAuthMock: XRPCCallable {
  nonisolated func getProxy(nsid _: String) -> String? { nil }

  func response(_ components: XRPCRequestComponents) async throws -> Data {
    guard components.nsId == "com.atproto.server.getServiceAuth" else {
      throw TangledError.notImplemented(components.nsId)
    }
    return Data(#"{"token":"service-token"}"#.utf8)
  }
}
