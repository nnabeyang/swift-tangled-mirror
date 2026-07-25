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
      pullRequestStatus: { _ in .open },
      patch: { uri in
        Data((uri == selectedURI ? "selected patch" : "dependency patch").utf8)
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
      merge: { _, _, _, _, _, _, _, _, _ in }
    )
  }

  private func pullRequest(uri: String, dependentOn: String?) -> TangledRecord<PullRequest> {
    TangledRecord(
      uri: uri,
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
}

private actor MergeRecorder {
  private var patch: String?

  func recordCheckedPatch(_ patch: String) {
    self.patch = patch
  }

  func checkedPatch() -> String? {
    patch
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
