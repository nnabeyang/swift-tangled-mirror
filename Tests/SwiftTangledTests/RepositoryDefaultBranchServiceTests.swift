import Foundation
import SwiftAtproto
import SwiftTangled
import TangledLexicons
import Testing

@testable import SwiftTangled

@Suite struct RepositoryDefaultBranchServiceTests {
  @Test func viewPreservesRecordsWithoutRepositoryDID() async throws {
    let record = TangledRecord(
      uri: "at://did:plc:owner/sh.tangled.repo/core",
      cid: "bafyreirepository",
      value: Repository(
        name: "core",
        knot: "knot.example",
        createdAt: FormatString(rawValue: "2026-08-01T00:00:00Z")
      )
    )
    let service = RepositoryDefaultBranchService(
      dependencies: RepositoryDefaultBranchDependencies(
        repository: { _ in record },
        defaultBranch: { _, _ in
          Issue.record("default branch should not be requested without a repository DID")
          return defaultBranch("main")
        },
        branch: { _, _, name in
          GitReference(name: name, hash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        },
        setDefaultBranch: { _, _, _, _ in }
      )
    )

    let view = try await service.view(repository: "alice.example/core")

    #expect(view.record == record)
    #expect(view.defaultBranch == nil)
  }

  @Test func changesAnExistingBranchWithServiceAuthentication() async throws {
    let recorder = DefaultBranchRecorder(defaultBranches: [defaultBranch("main")])
    let service = makeService(recorder: recorder)
    let plan = try await service.prepareChange(
      repository: "alice.example/core",
      branch: "release"
    )
    let result = try await service.change(plan, pdsClient: makePDSClient())

    #expect(result.outcome == .changed)
    #expect(result.oldBranch == "main")
    #expect(result.newBranch == "release")
    #expect(result.repository.uri == sampleRepository().uri)
    #expect(await recorder.branchNames() == ["release"])
    #expect(await recorder.setBranches() == ["release"])
  }

  @Test func noOpSkipsBranchLookupAndWrite() async throws {
    let recorder = DefaultBranchRecorder(defaultBranches: [defaultBranch("main")])
    let service = makeService(recorder: recorder)
    let plan = try await service.prepareChange(
      repository: "alice.example/core",
      branch: " main "
    )
    let result = try await service.change(plan, pdsClient: makePDSClient())

    #expect(!plan.requiresChange)
    #expect(result.outcome == .unchanged)
    #expect(await recorder.branchNames().isEmpty)
    #expect(await recorder.setBranches().isEmpty)
  }

  @Test func rejectsMissingBranchAndUninitializedRepositoryBeforeWrite() async {
    let missingRecorder = DefaultBranchRecorder(
      defaultBranches: [defaultBranch("main")],
      branchMissing: true
    )
    await #expect(throws: TangledError.self) {
      _ = try await makeService(recorder: missingRecorder).prepareChange(
        repository: "alice.example/core",
        branch: "missing"
      )
    }
    #expect(await missingRecorder.setBranches().isEmpty)

    let uninitializedRecorder = DefaultBranchRecorder(
      defaultBranches: [],
      defaultBranchInvalid: true
    )
    await #expect(throws: TangledError.self) {
      _ = try await makeService(recorder: uninitializedRecorder).prepareChange(
        repository: "alice.example/core",
        branch: "main"
      )
    }
    #expect(await uninitializedRecorder.branchNames().isEmpty)
  }

  @Test func ambiguousWriteIsVerifiedWithoutRetry() async throws {
    let appliedRecorder = DefaultBranchRecorder(
      defaultBranches: [defaultBranch("main"), defaultBranch("release")],
      setFailure: .serviceUnavailable("timeout")
    )
    let appliedService = makeService(recorder: appliedRecorder)
    let appliedPlan = try await appliedService.prepareChange(
      repository: "alice.example/core",
      branch: "release"
    )
    let applied = try await appliedService.change(appliedPlan, pdsClient: makePDSClient())
    #expect(applied.outcome == .changed)
    #expect(await appliedRecorder.setBranches() == ["release"])

    let unknownRecorder = DefaultBranchRecorder(
      defaultBranches: [defaultBranch("main"), defaultBranch("main")],
      setFailure: .serviceUnavailable("timeout")
    )
    let unknownService = makeService(recorder: unknownRecorder)
    let unknownPlan = try await unknownService.prepareChange(
      repository: "alice.example/core",
      branch: "release"
    )
    let unknown = try await unknownService.change(unknownPlan, pdsClient: makePDSClient())
    #expect(unknown.outcome == .outcomeUnknown)
    #expect(await unknownRecorder.setBranches() == ["release"])
  }

  @Test func permissionAndUnsupportedErrorsStayDistinct() async throws {
    let forbiddenRecorder = DefaultBranchRecorder(
      defaultBranches: [defaultBranch("main")],
      setFailure: .forbidden("owner required")
    )
    let forbiddenService = makeService(recorder: forbiddenRecorder)
    let forbiddenPlan = try await forbiddenService.prepareChange(
      repository: "alice.example/core",
      branch: "release"
    )
    await #expect(throws: TangledError.self) {
      _ = try await forbiddenService.change(forbiddenPlan, pdsClient: makePDSClient())
    }

    let unsupportedRecorder = DefaultBranchRecorder(
      defaultBranches: [defaultBranch("main")],
      setUnsupported: true
    )
    let unsupportedService = makeService(recorder: unsupportedRecorder)
    let unsupportedPlan = try await unsupportedService.prepareChange(
      repository: "alice.example/core",
      branch: "release"
    )
    do {
      _ = try await unsupportedService.change(unsupportedPlan, pdsClient: makePDSClient())
      Issue.record("expected notImplemented")
    } catch TangledError.notImplemented {
      // Expected.
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  private func makeService(
    recorder: DefaultBranchRecorder
  ) -> RepositoryDefaultBranchService {
    RepositoryDefaultBranchService(
      dependencies: RepositoryDefaultBranchDependencies(
        repository: { _ in sampleRepository() },
        defaultBranch: { _, _ in try await recorder.nextDefaultBranch() },
        branch: { _, _, name in try await recorder.branch(name) },
        setDefaultBranch: { _, _, _, branch in try await recorder.set(branch) }
      )
    )
  }

  private func makePDSClient() -> PDSClient {
    PDSClient(
      client: DefaultBranchServiceAuthMock(),
      repoDID: "did:plc:owner",
      authorizedScopes: [
        "atproto",
        "rpc:sh.tangled.repo.setDefaultBranch?aud=*",
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

private func defaultBranch(_ name: String) -> GitDefaultBranch {
  GitDefaultBranch(
    name: name,
    hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    when: FormatString(rawValue: "2026-08-01T00:00:00Z")
  )
}

private actor DefaultBranchRecorder {
  private var defaultBranches: [GitDefaultBranch]
  private let defaultBranchInvalid: Bool
  private let branchMissing: Bool
  private let setFailure: TangledError?
  private let setUnsupported: Bool
  private var branches: [String] = []
  private var sets: [String] = []

  init(
    defaultBranches: [GitDefaultBranch],
    defaultBranchInvalid: Bool = false,
    branchMissing: Bool = false,
    setFailure: TangledError? = nil,
    setUnsupported: Bool = false
  ) {
    self.defaultBranches = defaultBranches
    self.defaultBranchInvalid = defaultBranchInvalid
    self.branchMissing = branchMissing
    self.setFailure = setFailure
    self.setUnsupported = setUnsupported
  }

  func nextDefaultBranch() throws -> GitDefaultBranch {
    if defaultBranchInvalid {
      throw Sh.Tangled.RepoGetDefaultBranch.Error.invalidrequest("not initialized")
    }
    return defaultBranches.removeFirst()
  }

  func branch(_ name: String) throws -> GitReference {
    branches.append(name)
    if branchMissing {
      throw Sh.Tangled.RepoBranch.Error.branchnotfound("missing")
    }
    return GitReference(name: name, hash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
  }

  func set(_ branch: String) throws {
    sets.append(branch)
    if setUnsupported {
      throw Sh.Tangled.RepoSetDefaultBranch.Error.unexpected(
        error: "MethodNotFound",
        message: "unsupported"
      )
    }
    if let setFailure { throw setFailure }
  }

  func branchNames() -> [String] { branches }
  func setBranches() -> [String] { sets }
}

private actor DefaultBranchServiceAuthMock: XRPCCallable {
  nonisolated func getProxy(nsid _: String) -> String? { nil }

  func response(_ components: XRPCRequestComponents) async throws -> Data {
    guard components.nsId == "com.atproto.server.getServiceAuth" else {
      throw TangledError.notImplemented(components.nsId)
    }
    return Data(#"{"token":"service-token"}"#.utf8)
  }
}
