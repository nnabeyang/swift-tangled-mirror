import Foundation
import SwiftAtproto
import TangledLexicons
import Testing

@testable import SwiftTangled

@Suite struct PullRequestMergeServiceTests {
  @Test func checkCombinesStackPatchesFromDependencyToSelectedPullRequest() async throws {
    let selectedURI = "at://did:plc:author/sh.tangled.repo.pull/selected"
    let dependencyURI = "at://did:plc:author/sh.tangled.repo.pull/dependency"
    let recorder = MergeRecorder()
    let service = PullRequestMergeService(
      dependencies: dependencies(
        selectedURI: selectedURI,
        dependencyURI: dependencyURI,
        recorder: recorder
      )
    )

    let result = try await service.check(pullRequestURI: selectedURI)

    #expect(result.pullRequestURIs == [selectedURI, dependencyURI])
    #expect(result.canMerge)
    #expect(await recorder.checkedPatch() == "dependency patch\nselected patch")
  }

  @Test func mergeRequiresExplicitStackPermissionBeforeCallingKnot() async throws {
    let selectedURI = "at://did:plc:author/sh.tangled.repo.pull/selected"
    let dependencyURI = "at://did:plc:author/sh.tangled.repo.pull/dependency"
    let recorder = MergeRecorder()
    let service = PullRequestMergeService(
      dependencies: dependencies(
        selectedURI: selectedURI,
        dependencyURI: dependencyURI,
        recorder: recorder
      )
    )
    let pds = PDSClient(
      client: UnusedXRPCClient(),
      repoDID: "did:plc:user",
      authorizedScopes: []
    )

    await #expect(throws: TangledError.self) {
      _ = try await service.merge(
        pullRequestURI: selectedURI,
        allowStack: false,
        pdsClient: pds
      )
    }
    #expect(await recorder.checkedPatch() == nil)
  }

  @Test func checkUsesAuthoritativePatchWithoutIndexedState() async throws {
    let uri = "at://did:plc:author/sh.tangled.repo.pull/selected"
    let recorder = MergeRecorder()
    let record = pullRequest(uri: uri, dependentOn: nil)
    let service = PullRequestMergeService(
      dependencies: singleDependencies(
        record: { _ in record },
        indexedState: { _ in
          throw TangledError.notFound("not indexed")
        },
        recorder: recorder
      )
    )

    let result = try await service.check(pullRequestURI: uri)

    #expect(result.canMerge)
    #expect(await recorder.checkedPatch() == "latest patch")
  }

  @Test func mergeRejectsIndexedCIDMismatchBeforeKnot() async throws {
    let uri = "at://did:plc:author/sh.tangled.repo.pull/selected"
    let recorder = MergeRecorder()
    let authoritative = pullRequest(uri: uri, dependentOn: nil)
    let stale = TangledRecord(
      uri: uri,
      cid: "bafystale",
      value: authoritative.value
    )
    let service = PullRequestMergeService(
      dependencies: singleDependencies(
        record: { _ in authoritative },
        indexedState: { _ in
          PullRequestIndexedState(record: stale, status: .open)
        },
        recorder: recorder
      )
    )

    do {
      _ = try await service.merge(
        pullRequestURI: uri,
        allowStack: false,
        pdsClient: self.unusedPDSClient()
      )
      Issue.record("expected stale Bobbin state to fail")
    } catch TangledError.upstreamFailed(let message) {
      #expect(message == "Bobbin has not indexed the latest pull request record: \(uri)")
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(await recorder.checkedPatch() == nil)
  }

  @Test func mergeRejectsLatestClosedStatusBeforeKnot() async throws {
    let uri = "at://did:plc:author/sh.tangled.repo.pull/selected"
    let recorder = MergeRecorder()
    let record = pullRequest(uri: uri, dependentOn: nil)
    let service = PullRequestMergeService(
      dependencies: singleDependencies(
        record: { _ in record },
        indexedState: { _ in
          PullRequestIndexedState(record: record, status: .closed)
        },
        recorder: recorder
      )
    )

    do {
      _ = try await service.merge(
        pullRequestURI: uri,
        allowStack: false,
        pdsClient: self.unusedPDSClient()
      )
      Issue.record("expected closed pull request to fail")
    } catch TangledError.invalidRequest(let message) {
      #expect(message == "pull request is not open: \(uri)")
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(await recorder.checkedPatch() == nil)
  }

  @Test func mergeRejectsPullRequestChangedAfterMergeCheck() async throws {
    let uri = "at://did:plc:author/sh.tangled.repo.pull/selected"
    let recorder = MergeRecorder()
    let initial = pullRequest(uri: uri, dependentOn: nil)
    let updated = TangledRecord(
      uri: uri,
      cid: "bafyupdated",
      value: initial.value
    )
    let reads = PullRequestReadSequence(records: [initial, updated])
    let service = PullRequestMergeService(
      dependencies: singleDependencies(
        record: { _ in try await reads.next() },
        indexedState: { _ in
          PullRequestIndexedState(record: initial, status: .open)
        },
        recorder: recorder
      )
    )

    do {
      _ = try await service.merge(
        pullRequestURI: uri,
        allowStack: false,
        pdsClient: self.unusedPDSClient()
      )
      Issue.record("expected changed pull request to fail")
    } catch TangledError.conflict(let message) {
      #expect(
        message
          == "pull request changed during merge check: \(uri); fetch the latest state and retry"
      )
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(await recorder.checkedPatch() == "latest patch")
  }

  @Test func mergeClassifiesKnotConflicts() async throws {
    let uri = "at://did:plc:author/sh.tangled.repo.pull/selected"
    let recorder = MergeRecorder()
    let record = pullRequest(uri: uri, dependentOn: nil)
    let service = PullRequestMergeService(
      dependencies: singleDependencies(
        record: { _ in record },
        indexedState: { _ in PullRequestIndexedState(record: record, status: .open) },
        recorder: recorder,
        mergeCheck: {
          PullRequestMergeCheckResponse(
            isConflicted: true,
            conflicts: [.init(filename: "Sources/Feature.swift", reason: "content")]
          )
        }
      )
    )

    do {
      _ = try await service.merge(
        pullRequestURI: uri,
        allowStack: false,
        pdsClient: unusedPDSClient()
      )
      Issue.record("expected merge conflict")
    } catch TangledError.conflict(let message) {
      #expect(message == "merge conflicts: Sources/Feature.swift")
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test func mergeClassifiesStatusChangeAfterMergeCheck() async throws {
    let uri = "at://did:plc:author/sh.tangled.repo.pull/selected"
    let recorder = MergeRecorder()
    let record = pullRequest(uri: uri, dependentOn: nil)
    let states = PullRequestIndexedStateSequence(states: [
      PullRequestIndexedState(record: record, status: .open),
      PullRequestIndexedState(record: record, status: .closed),
    ])
    let service = PullRequestMergeService(
      dependencies: singleDependencies(
        record: { _ in record },
        indexedState: { _ in try await states.next() },
        recorder: recorder
      )
    )

    do {
      _ = try await service.merge(
        pullRequestURI: uri,
        allowStack: false,
        pdsClient: unusedPDSClient()
      )
      Issue.record("expected status conflict")
    } catch TangledError.conflict(let message) {
      #expect(
        message
          == "pull request is no longer open after merge check: \(uri); review the latest status before merging"
      )
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test func mergeClassifiesMissingAuthoritativeCIDAsUpstreamFailure() async throws {
    let uri = "at://did:plc:author/sh.tangled.repo.pull/selected"
    let recorder = MergeRecorder()
    let record = TangledRecord(
      uri: uri,
      value: pullRequest(uri: uri, dependentOn: nil).value
    )
    let service = PullRequestMergeService(
      dependencies: singleDependencies(
        record: { _ in record },
        indexedState: { _ in PullRequestIndexedState(record: record, status: .open) },
        recorder: recorder
      )
    )

    do {
      _ = try await service.merge(
        pullRequestURI: uri,
        allowStack: false,
        pdsClient: unusedPDSClient()
      )
      Issue.record("expected missing CID to fail")
    } catch TangledError.upstreamFailed(let message) {
      #expect(message == "PDS pull request record does not expose a CID: \(uri)")
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test func mergeReturnsPartialSuccessWhenStatusRecordsFail() async throws {
    let uri = "at://did:plc:author/sh.tangled.repo.pull/selected"
    let recorder = MergeRecorder()
    let record = pullRequest(uri: uri, dependentOn: nil)
    let service = PullRequestMergeService(
      dependencies: singleDependencies(
        record: { _ in record },
        indexedState: { _ in PullRequestIndexedState(record: record, status: .open) },
        recorder: recorder,
        markPullRequestsMerged: { _, _ in
          throw TangledError.upstreamFailed("status write failed")
        }
      )
    )

    let result = try await service.merge(
      pullRequestURI: uri,
      allowStack: false,
      pdsClient: unusedPDSClient()
    )

    #expect(result.outcome == .mergedStatusRecordsFailed)
    #expect(result.statusRecords.isEmpty)
    #expect(result.statusRecordError?.contains("status write failed") == true)
    #expect(await recorder.mergeCount() == 1)
  }

  @Test func mergeReturnsStatusRecordsOnFullSuccess() async throws {
    let uri = "at://did:plc:author/sh.tangled.repo.pull/selected"
    let recorder = MergeRecorder()
    let record = pullRequest(uri: uri, dependentOn: nil)
    let status = statusRecord(pullRequestURI: uri)
    let service = PullRequestMergeService(
      dependencies: singleDependencies(
        record: { _ in record },
        indexedState: { _ in PullRequestIndexedState(record: record, status: .open) },
        recorder: recorder,
        markPullRequestsMerged: { _, _ in [status] }
      )
    )

    let result = try await service.merge(
      pullRequestURI: uri,
      allowStack: false,
      pdsClient: unusedPDSClient()
    )

    #expect(result.outcome == .merged)
    #expect(result.statusRecords == [status])
    #expect(result.statusRecordError == nil)
    #expect(await recorder.mergeCount() == 1)
  }

  private func dependencies(
    selectedURI: String,
    dependencyURI: String,
    recorder: MergeRecorder
  ) -> PullRequestMergeDependencies {
    PullRequestMergeDependencies(
      pullRequest: { uri in
        self.pullRequest(
          uri: uri,
          dependentOn: uri == selectedURI ? dependencyURI : nil
        )
      },
      indexedState: { uri in
        PullRequestIndexedState(
          record: self.pullRequest(
            uri: uri,
            dependentOn: uri == selectedURI ? dependencyURI : nil
          ),
          status: .open
        )
      },
      patch: { record in
        Data((record.uri == selectedURI ? "selected patch" : "dependency patch").utf8)
      },
      repository: { _ in
        TangledRecord(
          uri: "at://did:plc:owner/sh.tangled.repo/core",
          value: Repository(
            name: "core",
            knot: "knot1.tangled.sh",
            repoDID: "did:plc:repository",
            createdAt: FormatString<Date>(rawValue: "2026-07-24T00:00:00Z")
          )
        )
      },
      mergeCheck: { _, _, _, _, _, patch in
        await recorder.recordCheckedPatch(patch)
        return PullRequestMergeCheckResponse(isConflicted: false)
      },
      merge: { _, _, _, _, _, _, _, _, _ in
        await recorder.recordMerge()
      },
      serviceAuthToken: { _, _, _ in "token" },
      markPullRequestsMerged: { _, _ in [] }
    )
  }

  private func pullRequest(uri: String, dependentOn: String?) -> TangledRecord<PullRequest> {
    TangledRecord(
      uri: uri,
      cid: "bafy\(uri.split(separator: "/").last ?? "pull")",
      value: PullRequest(
        title: "Merge",
        rounds: [],
        target: PullRequestTarget(
          branch: "main",
          repositoryDID: "did:plc:repository"
        ),
        createdAt: FormatString<Date>(rawValue: "2026-07-24T00:00:00Z"),
        dependentOn: dependentOn
      )
    )
  }

  private func singleDependencies(
    record: @escaping @Sendable (String) async throws -> TangledRecord<PullRequest>,
    indexedState: @escaping @Sendable (String) async throws -> PullRequestIndexedState,
    recorder: MergeRecorder,
    mergeCheck:
      @escaping @Sendable () async throws -> PullRequestMergeCheckResponse = {
        PullRequestMergeCheckResponse(isConflicted: false)
      },
    markPullRequestsMerged:
      @escaping @Sendable (PDSClient, [String]) async throws -> [TangledRecord<PullRequestStatusChange>] = { _, _ in [] }
  ) -> PullRequestMergeDependencies {
    PullRequestMergeDependencies(
      pullRequest: record,
      indexedState: indexedState,
      patch: { _ in Data("latest patch".utf8) },
      repository: { _ in
        TangledRecord(
          uri: "at://did:plc:owner/sh.tangled.repo/core",
          value: Repository(
            name: "core",
            knot: "knot1.tangled.sh",
            repoDID: "did:plc:repository",
            createdAt: FormatString<Date>(rawValue: "2026-07-24T00:00:00Z")
          )
        )
      },
      mergeCheck: { _, _, _, _, _, patch in
        await recorder.recordCheckedPatch(patch)
        return try await mergeCheck()
      },
      merge: { _, _, _, _, _, _, _, _, _ in
        await recorder.recordMerge()
      },
      serviceAuthToken: { _, _, _ in "token" },
      markPullRequestsMerged: markPullRequestsMerged
    )
  }

  private func statusRecord(pullRequestURI: String) -> TangledRecord<PullRequestStatusChange> {
    TangledRecord(
      uri: "at://did:plc:author/sh.tangled.repo.pull.status/merged",
      cid: "bafystatus",
      value: PullRequestStatusChange(
        pullRequestURI: pullRequestURI,
        status: .merged,
        createdAt: FormatString<Date>(rawValue: "2026-07-24T00:00:00Z")
      )
    )
  }

  private func unusedPDSClient() -> PDSClient {
    PDSClient(
      client: UnusedXRPCClient(),
      repoDID: "did:plc:user",
      authorizedScopes: []
    )
  }
}

private actor MergeRecorder {
  private var patch: String?
  private var merges = 0

  func recordCheckedPatch(_ patch: String) {
    self.patch = patch
  }

  func checkedPatch() -> String? {
    patch
  }

  func recordMerge() {
    merges += 1
  }

  func mergeCount() -> Int {
    merges
  }
}

private actor PullRequestReadSequence {
  private var records: [TangledRecord<PullRequest>]

  init(records: [TangledRecord<PullRequest>]) {
    self.records = records
  }

  func next() throws -> TangledRecord<PullRequest> {
    guard !records.isEmpty else {
      throw TangledError.notFound("no pull request record")
    }
    return records.removeFirst()
  }
}

private actor PullRequestIndexedStateSequence {
  private var states: [PullRequestIndexedState]

  init(states: [PullRequestIndexedState]) {
    self.states = states
  }

  func next() throws -> PullRequestIndexedState {
    guard !states.isEmpty else {
      throw TangledError.notFound("no indexed pull request state")
    }
    return states.removeFirst()
  }
}

private struct UnusedXRPCClient: XRPCCallable {
  func getProxy(nsid: String) -> String? {
    nil
  }

  func response(_ components: XRPCRequestComponents) async throws -> Data {
    throw TangledError.transport("unexpected XRPC request")
  }
}
