import Foundation
import SwiftAtproto
import SwiftTangled
import TangledLexicons
import Testing

@testable import SwiftTangled

@Suite struct RepositoryLifecycleServiceTests {
  private let ownerDID = "did:plc:owner"
  private let repositoryDID = "did:plc:repository"
  private let createdAt = FormatString<Date>(rawValue: "2026-08-01T12:00:00Z")

  @Test func pdsCreatesAndDeletesRepositoryRecordsWithExclusiveWrites() async throws {
    let mock = RepositoryLifecycleXRPCMock(ownerDID: ownerDID)
    let client = makePDSClient(mock)
    let record = try await client.createRepositoryRecord(
      rkey: "example",
      name: "Example",
      knot: "knot.example",
      source: "https://example.com/source.git",
      repositoryDID: repositoryDID
    )
    #expect(record.uri == "at://\(ownerDID)/sh.tangled.repo/example")
    #expect(record.value.repoDID == repositoryDID)
    #expect(record.value.source == "https://example.com/source.git")

    try await client.deleteRepositoryRecord(record)
    let requests = await mock.requests()
    #expect(requests.map(\.nsID) == ["com.atproto.repo.createRecord", "com.atproto.repo.deleteRecord"])
    let create = try JSONDecoder().decode(
      Com.Atproto.RepoCreateRecord_Input.self,
      from: try #require(requests[0].body)
    )
    #expect(create.rkey?.rawValue == "example")
    guard case .record(let value) = create.record, let repository = value as? Sh.Tangled.Repo else {
      Issue.record("expected repository record")
      return
    }
    #expect(repository.name == "Example")
    #expect(repository.repoDid?.rawValue == repositoryDID)
    let delete = try JSONDecoder().decode(
      Com.Atproto.RepoDeleteRecord_Input.self,
      from: try #require(requests[1].body)
    )
    #expect(delete.swapRecord?.rawValue == "bafyrepopresent")
  }

  @Test func createNormalizesNameAndReturnsBothURLs() async throws {
    let pds = makePDSClient(RepositoryLifecycleXRPCMock(ownerDID: ownerDID))
    let recorder = LifecycleRecorder()
    let service = makeService(recorder: recorder)
    let result = try await service.create(
      RepositoryCreationRequest(
        name: " Example.git ",
        knot: "knot.example",
        source: "https://example.com/source.git"
      ),
      pdsClient: pds
    )

    #expect(result.outcome == .created)
    #expect(result.target.name == "Example")
    #expect(result.target.rkey == "example")
    #expect(result.target.webURL == "https://tangled.org/\(ownerDID)/example")
    #expect(result.target.cloneURL == "https://knot.example/\(repositoryDID)")
    #expect(await recorder.createdNames() == ["example"])
  }

  @Test func failedRecordCreationAttemptsCleanupExactlyOnce() async throws {
    let pds = makePDSClient(
      RepositoryLifecycleXRPCMock(
        ownerDID: ownerDID,
        failingNSID: "com.atproto.repo.createRecord"
      )
    )
    let recorder = LifecycleRecorder()
    let service = makeService(recorder: recorder)
    let result = try await service.create(
      RepositoryCreationRequest(name: "example", knot: "knot.example"),
      pdsClient: pds
    )

    #expect(result.outcome == .rolledBack)
    #expect(await recorder.deletedNames() == ["example"])
  }

  @Test func cleanupFailureIsReportedAsPartialSuccessWithoutRetry() async throws {
    let pds = makePDSClient(
      RepositoryLifecycleXRPCMock(
        ownerDID: ownerDID,
        failingNSID: "com.atproto.repo.createRecord"
      )
    )
    let recorder = LifecycleRecorder(deleteError: TangledError.forbidden("denied"))
    let service = makeService(recorder: recorder)
    let result = try await service.create(
      RepositoryCreationRequest(name: "example", knot: "knot.example"),
      pdsClient: pds
    )

    #expect(result.outcome == .knotCreatedRecordFailed)
    #expect(result.cleanupError != nil)
    #expect(await recorder.deletedNames() == ["example"])
  }

  private func makePDSClient(_ mock: RepositoryLifecycleXRPCMock) -> PDSClient {
    PDSClient(
      client: mock,
      repoDID: ownerDID,
      authorizedScopes: [
        "atproto",
        "repo:sh.tangled.repo",
        "rpc:sh.tangled.repo.create?aud=*",
        "rpc:sh.tangled.repo.delete?aud=*",
      ],
      now: { createdAt.typed! }
    )
  }

  private func makeService(recorder: LifecycleRecorder) -> RepositoryLifecycleService {
    RepositoryLifecycleService(
      dependencies: RepositoryLifecycleDependencies(
        repository: { _ in throw TangledError.notFound(nil) },
        record: { _ in throw TangledError.notFound(nil) },
        createOnKnot: { _, _, _, name, _, _, _ in
          await recorder.recordCreate(name)
          return repositoryDID
        },
        deleteOnKnot: { _, _, _, name, _ in
          try await recorder.recordDelete(name)
        }
      )
    )
  }
}

private actor LifecycleRecorder {
  private var creates: [String] = []
  private var deletes: [String] = []
  private let deleteError: (any Error)?

  init(deleteError: (any Error)? = nil) {
    self.deleteError = deleteError
  }

  func recordCreate(_ name: String) {
    creates.append(name)
  }

  func recordDelete(_ name: String) throws {
    deletes.append(name)
    if let deleteError { throw deleteError }
  }

  func createdNames() -> [String] { creates }
  func deletedNames() -> [String] { deletes }
}

private actor RepositoryLifecycleXRPCMock: XRPCCallable {
  struct Request: Sendable {
    let nsID: String
    let body: Data?
  }

  private let ownerDID: String
  private let failingNSID: String?
  private var recorded: [Request] = []

  init(ownerDID: String, failingNSID: String? = nil) {
    self.ownerDID = ownerDID
    self.failingNSID = failingNSID
  }

  nonisolated func getProxy(nsid _: String) -> String? { nil }

  func response(_ components: XRPCRequestComponents) async throws -> Data {
    recorded.append(Request(nsID: components.nsId, body: components.body))
    if components.nsId == failingNSID {
      throw TangledError.conflict("record exists")
    }
    switch components.nsId {
    case "com.atproto.server.getServiceAuth":
      return Data(#"{"token":"service-token"}"#.utf8)
    case "com.atproto.repo.createRecord":
      return Data(
        """
        {"uri":"at://\(ownerDID)/sh.tangled.repo/example","cid":"bafyrepopresent"}
        """.utf8
      )
    case "com.atproto.repo.deleteRecord":
      return Data("{}".utf8)
    default:
      throw TangledError.notImplemented(components.nsId)
    }
  }

  func requests() -> [Request] { recorded }
}
