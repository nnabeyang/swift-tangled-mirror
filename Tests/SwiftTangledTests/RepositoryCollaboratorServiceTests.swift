import Foundation
import SwiftAtproto
import SwiftTangled
import TangledLexicons
import Testing

@testable import SwiftTangled

@Suite struct RepositoryCollaboratorServiceTests {
  private let collaborator = RepositoryCollaborator(
    subjectDID: "did:plc:collaborator",
    addedByDID: "did:plc:owner",
    createdAt: FormatString(rawValue: "2026-08-01T00:00:00Z")
  )

  @Test func resolvesDIDHandleAndAtHandle() async throws {
    let resolver = CollaboratorResolver()
    #expect(
      try await resolveCollaboratorDID("did:plc:collaborator", resolver: resolver)
        == "did:plc:collaborator"
    )
    #expect(
      try await resolveCollaboratorDID("alice.example", resolver: resolver)
        == "did:plc:collaborator"
    )
    #expect(
      try await resolveCollaboratorDID("@alice.example", resolver: resolver)
        == "did:plc:collaborator"
    )
  }

  @Test func addReportsExistingButStillCallsKnotToHealDrift() async throws {
    let recorder = CollaboratorRecorder()
    let service = makeService(recorder: recorder, collaborators: [collaborator])
    let result = try await service.add(
      repository: "alice.example/core",
      collaborator: "alice.example",
      pdsClient: makePDSClient()
    )
    #expect(result.outcome == .alreadyPresent)
    #expect(await recorder.addCount() == 1)
    #expect(result.target.repositoryDID == "did:plc:repository")
  }

  @Test func absentRemovalReturnsNotPresentWithoutKnotWrite() async throws {
    let recorder = CollaboratorRecorder()
    let service = makeService(recorder: recorder, collaborators: [])
    let plan = try await service.prepareRemoval(
      repository: "alice.example/core",
      collaborator: "alice.example",
      pdsClient: makePDSClient()
    )
    #expect(!plan.isPresent)
    let result = try await service.remove(plan, pdsClient: makePDSClient())
    #expect(result.outcome == .notPresent)
    #expect(await recorder.removeCount() == 0)
  }

  @Test func ambiguousAddReturnsUnknownWithoutRetry() async throws {
    let recorder = CollaboratorRecorder(addError: TangledError.serviceUnavailable("timeout"))
    let service = makeService(recorder: recorder, collaborators: [])
    let result = try await service.add(
      repository: "alice.example/core",
      collaborator: "alice.example",
      pdsClient: makePDSClient()
    )
    #expect(result.outcome == .outcomeUnknown)
    #expect(await recorder.addCount() == 1)
  }

  @Test func rejectsOwnerAndKnotWithoutCapability() async throws {
    let recorder = CollaboratorRecorder()
    let ownerService = makeService(
      recorder: recorder,
      collaborators: [],
      collaboratorDID: "did:plc:owner"
    )
    await #expect(throws: TangledError.self) {
      _ = try await ownerService.add(
        repository: "alice.example/core",
        collaborator: "owner.example",
        pdsClient: makePDSClient()
      )
    }

    let legacyService = makeService(recorder: recorder, collaborators: [], capabilities: [])
    await #expect(throws: TangledError.self) {
      _ = try await legacyService.collaborators(repository: "alice.example/core")
    }
  }

  private func makeService(
    recorder: CollaboratorRecorder,
    collaborators: [RepositoryCollaborator],
    collaboratorDID: String = "did:plc:collaborator",
    capabilities: Set<String> = ["knot-acl"]
  ) -> RepositoryCollaboratorService {
    RepositoryCollaboratorService(
      dependencies: RepositoryCollaboratorDependencies(
        repository: { _ in sampleRepository() },
        resolveCollaboratorDID: { _ in collaboratorDID },
        capabilities: { _ in capabilities },
        collaborators: { _, _, _, _, _ in Page(items: collaborators) },
        add: { _, _, _, _ in try await recorder.add() },
        remove: { _, _, _, _ in await recorder.remove() }
      )
    )
  }

  private func makePDSClient() -> PDSClient {
    PDSClient(
      client: CollaboratorServiceAuthMock(),
      repoDID: "did:plc:owner",
      authorizedScopes: [
        "atproto",
        "rpc:sh.tangled.repo.addCollaborator?aud=*",
        "rpc:sh.tangled.repo.removeCollaborator?aud=*",
      ]
    )
  }
}

private func sampleRepository() -> TangledRecord<Repository> {
  TangledRecord(
    uri: "at://did:plc:owner/sh.tangled.repo/core",
    cid: "bafyreirepository",
    value: Repository(
      name: "core",
      knot: "knot.example",
      repoDID: "did:plc:repository",
      createdAt: FormatString(rawValue: "2026-08-01T00:00:00Z")
    )
  )
}

private actor CollaboratorRecorder {
  private var adds = 0
  private var removes = 0
  private let addError: (any Error)?

  init(addError: (any Error)? = nil) { self.addError = addError }

  func add() throws {
    adds += 1
    if let addError { throw addError }
  }

  func remove() { removes += 1 }
  func addCount() -> Int { adds }
  func removeCount() -> Int { removes }
}

private actor CollaboratorServiceAuthMock: XRPCCallable {
  nonisolated func getProxy(nsid _: String) -> String? { nil }

  func response(_ components: XRPCRequestComponents) async throws -> Data {
    guard components.nsId == "com.atproto.server.getServiceAuth" else {
      throw TangledError.notImplemented(components.nsId)
    }
    return Data(#"{"token":"service-token"}"#.utf8)
  }
}

private struct CollaboratorResolver: ATPResolver {
  func resolve(handle: Handle) async throws -> DID? {
    handle.rawValue == "alice.example" ? try DID(string: "did:plc:collaborator") : nil
  }

  func resolve(did _: DID) async throws -> DIDDocument? { nil }
}
