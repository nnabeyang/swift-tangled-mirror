import Foundation
import SwiftAtproto
import TangledLexicons
import Testing

@testable import SwiftTangled

@Suite struct PullRequestResubmissionServiceTests {
  private let pullURI =
    "at://did:plc:author/sh.tangled.repo.pull/3mrresubmit"
  private let repositoryDID = "did:plc:repository"

  @Test func preparesAuthoritativeBranchPullAndAppendsNextRound() async throws {
    let snapshot = try makeSnapshot()
    let recorder = ResubmissionRecorder()
    let service = makeService(snapshot: snapshot, recorder: recorder)

    let context = try await service.prepare(pullRequestURI: pullURI)
    let result = try await service.resubmit(
      context,
      patch: patch(revision: String(repeating: "b", count: 40), file: "new"),
      sourceRevision: String(repeating: "b", count: 40),
      pdsClient: unusedPDSClient()
    )

    #expect(context.pullRequest.uri == pullURI)
    #expect(result.roundNumber == 1)
    #expect(result.pullRequest.value.rounds.count == 2)
    #expect(await recorder.appendCount() == 1)
  }

  @Test func unchangedRevisionAndPatchFailBeforeAppending() async throws {
    let snapshot = try makeSnapshot()
    let recorder = ResubmissionRecorder()
    let service = makeService(snapshot: snapshot, recorder: recorder)
    let context = try await service.prepare(pullRequestURI: pullURI)
    let previous = patch(revision: String(repeating: "a", count: 40), file: "old")

    await #expect(throws: TangledError.self) {
      _ = try await service.resubmit(
        context,
        patch: previous,
        sourceRevision: String(repeating: "b", count: 40),
        pdsClient: unusedPDSClient()
      )
    }
    await #expect(throws: TangledError.self) {
      _ = try await service.resubmit(
        context,
        patch: patch(revision: String(repeating: "a", count: 40), file: "changed"),
        sourceRevision: String(repeating: "a", count: 40),
        pdsClient: unusedPDSClient()
      )
    }
    #expect(await recorder.appendCount() == 0)
  }

  @Test func patchPullAcceptsDiffAndFormatPatch() async throws {
    for candidate in [
      Data("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n".utf8),
      patch(revision: String(repeating: "b", count: 40), file: "new"),
    ] {
      let snapshot = try makeSnapshot(source: nil)
      let recorder = ResubmissionRecorder()
      let service = makeService(snapshot: snapshot, recorder: recorder)
      let context = try await service.prepare(pullRequestURI: pullURI)

      let result = try await service.resubmit(
        context,
        patch: candidate,
        pdsClient: unusedPDSClient()
      )

      #expect(result.roundNumber == 1)
      #expect(await recorder.appendCount() == 1)
    }
  }

  @Test func patchPullRejectsMalformedIdenticalAndBranchMode() async throws {
    let snapshot = try makeSnapshot(source: nil)
    let recorder = ResubmissionRecorder()
    let service = makeService(snapshot: snapshot, recorder: recorder)
    let context = try await service.prepare(pullRequestURI: pullURI)

    for candidate in [
      Data("not a patch\nstill not a patch\n".utf8),
      patch(revision: String(repeating: "a", count: 40), file: "old"),
    ] {
      await #expect(throws: TangledError.self) {
        _ = try await service.resubmit(
          context,
          patch: candidate,
          pdsClient: unusedPDSClient()
        )
      }
    }
    await #expect(throws: TangledError.self) {
      _ = try await service.resubmit(
        context,
        patch: Data("diff --git a/a b/a\n--- a/a\n".utf8),
        sourceRevision: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        pdsClient: unusedPDSClient()
      )
    }
    #expect(await recorder.appendCount() == 0)
  }

  @Test func resubmitsForkUsingHiddenTrackingRef() async throws {
    let sourceRepositoryDID = "did:plc:fork"
    let snapshot = try makeSnapshot(
      source: PullRequestSource(
        branch: "feature",
        repositoryDID: sourceRepositoryDID
      )
    )
    let recorder = ResubmissionRecorder()
    let targetRepository = repository(
      uri: "at://did:plc:owner/sh.tangled.repo/example",
      repositoryDID: repositoryDID
    )
    let sourceRepository = repository(
      uri: "at://did:plc:fork-owner/sh.tangled.repo/example",
      repositoryDID: sourceRepositoryDID,
      source: repositoryDID
    )
    let newPatch = patch(revision: String(repeating: "b", count: 40), file: "new")
    let service = PullRequestResubmissionService(
      dependencies: PullRequestResubmissionDependencies(
        snapshot: { _ in snapshot },
        repository: { reference in
          switch reference {
          case self.repositoryDID:
            return targetRepository
          case sourceRepositoryDID:
            return sourceRepository
          default:
            throw TangledError.notFound(reference)
          }
        },
        list: { _, _, _, _ in
          Page(items: [.init(record: snapshot.record, status: .open, commentCount: -1)])
        },
        patch: { _ in
          self.patch(revision: String(repeating: "a", count: 40), file: "old")
        },
        updateHiddenRef: { knot, token, uri, source, target in
          await recorder.recordHiddenRef(
            [knot, token, uri, source, target]
          )
          return "hidden/feature/main"
        },
        compare: { knot, did, base, head in
          await recorder.recordComparison([knot, did, base, head])
          return GitComparison(
            baseRevision: String(repeating: "0", count: 40),
            headRevision: String(repeating: "b", count: 40),
            formatPatches: [],
            patch: String(decoding: newPatch, as: UTF8.self),
            combinedFiles: [],
            combinedPatch: ""
          )
        },
        appendRound: { current, _, _ in
          await recorder.recordAppend()
          return TangledRecord(
            uri: current.record.uri,
            cid: "bafyupdated",
            value: current.record.value
          )
        }
      )
    )

    let context = try await service.prepare(pullRequestURI: pullURI)
    let result = try await service.resubmitFork(
      context,
      pdsClient: serviceAuthPDSClient()
    )

    #expect(result.pullRequest.cid == "bafyupdated")
    #expect(
      await recorder.hiddenRefArguments()
        == [
          "knot.example",
          "service-token",
          sourceRepository.uri,
          "feature",
          "main",
        ]
    )
    #expect(
      await recorder.comparisonArguments()
        == [
          "knot.example",
          sourceRepositoryDID,
          "hidden/feature/main",
          "feature",
        ]
    )
    #expect(await recorder.appendCount() == 1)
  }

  @Test func rejectsForkWithMismatchedUpstream() async throws {
    let snapshot = try makeSnapshot(
      source: PullRequestSource(
        branch: "feature",
        repositoryDID: "did:plc:fork"
      )
    )
    let service = PullRequestResubmissionService(
      dependencies: dependencies(
        snapshot: snapshot,
        recorder: ResubmissionRecorder(),
        repository: { reference in
          if reference == "did:plc:fork" {
            return self.repository(
              uri: "at://did:plc:fork-owner/sh.tangled.repo/example",
              repositoryDID: reference,
              source: "did:plc:other"
            )
          }
          if reference == "did:plc:other" {
            return self.repository(
              uri: "at://did:plc:other/sh.tangled.repo/example",
              repositoryDID: reference
            )
          }
          return self.repository(
            uri: "at://did:plc:owner/sh.tangled.repo/example",
            repositoryDID: self.repositoryDID
          )
        }
      )
    )

    await #expect(throws: TangledError.self) {
      _ = try await service.prepare(pullRequestURI: pullURI)
    }
  }

  @Test func rejectsEitherStackDirection() async throws {
    let cases = [
      try makeSnapshot(dependentOn: "at://did:plc:author/sh.tangled.repo.pull/parent")
    ]
    for snapshot in cases {
      let service = makeService(snapshot: snapshot, recorder: ResubmissionRecorder())
      await #expect(throws: TangledError.self) {
        _ = try await service.prepare(pullRequestURI: pullURI)
      }
    }

    let snapshot = try makeSnapshot()
    let service = makeService(
      snapshot: snapshot,
      recorder: ResubmissionRecorder(),
      extraItems: [
        PullRequestListItem(
          record: TangledRecord(
            uri: "at://did:plc:author/sh.tangled.repo.pull/child",
            cid: "bafychild",
            value: PullRequest(
              title: "Child",
              rounds: snapshot.record.value.rounds,
              source: .init(branch: "child"),
              target: snapshot.record.value.target,
              createdAt: snapshot.record.value.createdAt,
              dependentOn: pullURI
            )
          ),
          status: .open,
          commentCount: -1
        )
      ]
    )
    await #expect(throws: TangledError.self) {
      _ = try await service.prepare(pullRequestURI: pullURI)
    }
  }
}

extension PullRequestResubmissionServiceTests {
  private func makeService(
    snapshot: PullRequestRecordSnapshot,
    recorder: ResubmissionRecorder,
    extraItems: [PullRequestListItem] = []
  ) -> PullRequestResubmissionService {
    PullRequestResubmissionService(
      dependencies: dependencies(
        snapshot: snapshot,
        recorder: recorder,
        extraItems: extraItems
      ))
  }

  private func dependencies(
    snapshot: PullRequestRecordSnapshot,
    recorder: ResubmissionRecorder,
    extraItems: [PullRequestListItem] = [],
    repository: (@Sendable (String) async throws -> TangledRecord<Repository>)? = nil
  ) -> PullRequestResubmissionDependencies {
    PullRequestResubmissionDependencies(
      snapshot: { _ in snapshot },
      repository: repository ?? { _ in
        self.repository(
          uri: "at://did:plc:owner/sh.tangled.repo/example",
          repositoryDID: self.repositoryDID
        )
      },
      list: { _, _, _, _ in
        Page(
          items: [
            PullRequestListItem(
              record: snapshot.record,
              status: .open,
              commentCount: -1
            )
          ] + extraItems
        )
      },
      patch: { _ in
        self.patch(
          revision: String(repeating: "a", count: 40),
          file: "old"
        )
      },
      updateHiddenRef: { _, _, _, source, target in
        "hidden/\(source)/\(target)"
      },
      compare: { _, _, _, _ in
        GitComparison(
          baseRevision: String(repeating: "0", count: 40),
          headRevision: String(repeating: "b", count: 40),
          formatPatches: [],
          patch: String(
            decoding: self.patch(
              revision: String(repeating: "b", count: 40),
              file: "new"
            ),
            as: UTF8.self
          ),
          combinedFiles: [],
          combinedPatch: ""
        )
      },
      appendRound: { current, _, _ in
        await recorder.recordAppend()
        let pull = current.record.value
        return TangledRecord(
          uri: current.record.uri,
          cid: "bafyupdated",
          value: PullRequest(
            title: pull.title,
            body: pull.body,
            rounds: pull.rounds + [
              PullRequestRound(
                createdAt: FormatString(rawValue: "2026-07-27T12:00:00Z"),
                patchBlob: BlobReference(
                  cid: "bafknew",
                  mimeType: "application/gzip",
                  size: 30
                )
              )
            ],
            source: pull.source,
            target: pull.target,
            createdAt: pull.createdAt,
            mentions: pull.mentions,
            references: pull.references,
            dependentOn: pull.dependentOn
          )
        )
      }
    )
  }

  private func repository(
    uri: String,
    repositoryDID: String,
    source: String? = nil
  ) -> TangledRecord<Repository> {
    TangledRecord(
      uri: uri,
      cid: "bafyrepo",
      value: Repository(
        name: "example",
        knot: "knot.example",
        source: source,
        repoDID: repositoryDID,
        createdAt: FormatString(rawValue: "2026-07-20T00:00:00Z")
      )
    )
  }

  private func makeSnapshot(
    source: PullRequestSource? = PullRequestSource(branch: "feature"),
    dependentOn: String? = nil
  ) throws -> PullRequestRecordSnapshot {
    let pull = PullRequest(
      title: "Resubmit",
      rounds: [
        PullRequestRound(
          createdAt: FormatString(rawValue: "2026-07-26T12:00:00Z"),
          patchBlob: BlobReference(
            cid: "bafkold",
            mimeType: "application/gzip",
            size: 20
          )
        )
      ],
      source: source,
      target: PullRequestTarget(branch: "main", repositoryDID: repositoryDID),
      createdAt: FormatString(rawValue: "2026-07-26T12:00:00Z"),
      dependentOn: dependentOn
    )
    let wire = Sh.Tangled.RepoPull(
      createdAt: pull.createdAt,
      dependentOn: dependentOn.map(FormatString.init(rawValue:)),
      rounds: [],
      source: source.map {
        .init(
          branch: $0.branch,
          repo: $0.repositoryDID.map(FormatString.init(rawValue:))
        )
      },
      target: .init(
        branch: pull.target.branch,
        repo: FormatString(rawValue: pull.target.repositoryDID)
      ),
      title: pull.title
    )
    return PullRequestRecordSnapshot(
      record: TangledRecord(uri: pullURI, cid: "bafycurrent", value: pull),
      rawValue: .record(wire)
    )
  }

  private func patch(revision: String, file: String) -> Data {
    Data(
      """
      From \(revision) Mon Sep 17 00:00:00 2001
      From: Author <author@example.com>
      Subject: [PATCH] \(file)

      diff --git a/\(file) b/\(file)

      """.utf8
    )
  }

  private func unusedPDSClient() -> PDSClient {
    PDSClient(
      client: UnusedResubmissionXRPCClient(),
      repoDID: "did:plc:author",
      authorizedScopes: []
    )
  }

  private func serviceAuthPDSClient() -> PDSClient {
    PDSClient(
      client: ServiceAuthResubmissionXRPCClient(),
      repoDID: "did:plc:author",
      authorizedScopes: ["rpc:sh.tangled.repo.hiddenRef?aud=*"]
    )
  }
}

private actor ResubmissionRecorder {
  private var count = 0
  private var hiddenRef: [String]?
  private var comparison: [String]?

  func recordAppend() {
    count += 1
  }

  func appendCount() -> Int {
    count
  }

  func recordHiddenRef(_ arguments: [String]) {
    hiddenRef = arguments
  }

  func hiddenRefArguments() -> [String]? {
    hiddenRef
  }

  func recordComparison(_ arguments: [String]) {
    comparison = arguments
  }

  func comparisonArguments() -> [String]? {
    comparison
  }
}

private struct UnusedResubmissionXRPCClient: XRPCCallable {
  func getProxy(nsid _: String) -> String? { nil }

  func response(_: XRPCRequestComponents) async throws -> Data {
    throw TangledError.invalidRequest("unexpected request")
  }
}

private struct ServiceAuthResubmissionXRPCClient: XRPCCallable {
  func getProxy(nsid _: String) -> String? { nil }

  func response(_ components: XRPCRequestComponents) async throws -> Data {
    guard components.nsId == "com.atproto.server.getServiceAuth" else {
      throw TangledError.invalidRequest("unexpected request")
    }
    return Data(#"{"token":"service-token"}"#.utf8)
  }
}
