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

  @Test func rejectsPatchForkAndEitherStackDirection() async throws {
    let cases = [
      try makeSnapshot(source: nil),
      try makeSnapshot(
        source: PullRequestSource(
          branch: "feature",
          repositoryDID: "did:plc:fork"
        )
      ),
      try makeSnapshot(dependentOn: "at://did:plc:author/sh.tangled.repo.pull/parent"),
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
      dependencies: PullRequestResubmissionDependencies(
        snapshot: { _ in snapshot },
        repository: { _ in
          TangledRecord(
            uri: "at://did:plc:owner/sh.tangled.repo/example",
            cid: "bafyrepo",
            value: Repository(
              name: "example",
              knot: "knot.example",
              repoDID: self.repositoryDID,
              createdAt: FormatString(rawValue: "2026-07-20T00:00:00Z")
            )
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
}

private actor ResubmissionRecorder {
  private var count = 0

  func recordAppend() {
    count += 1
  }

  func appendCount() -> Int {
    count
  }
}

private struct UnusedResubmissionXRPCClient: XRPCCallable {
  func getProxy(nsid _: String) -> String? { nil }

  func response(_: XRPCRequestComponents) async throws -> Data {
    throw TangledError.invalidRequest("unexpected request")
  }
}
