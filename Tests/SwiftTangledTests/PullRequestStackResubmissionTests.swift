import Foundation
import SwiftAtproto
import TangledLexicons
import Testing

@testable import SwiftTangled

@Suite struct PullRequestStackResubmissionTests {
  private let ownerDID = "did:plc:author"

  @Test func plansReorderUpdateCreateAndDeleteByChangeID() async throws {
    let first = try snapshot(key: "first", title: "First")
    let second = try snapshot(key: "second", title: "Second", dependentOn: first.record.uri)
    let third = try snapshot(key: "third", title: "Third", dependentOn: second.record.uri)
    let snapshots = Dictionary(
      uniqueKeysWithValues: [first, second, third].map { ($0.record.uri, $0) }
    )
    let patches = [
      first.record.uri: patch(changeID: "I-first", title: "First"),
      second.record.uri: patch(changeID: "I-second", title: "Second"),
      third.record.uri: patch(changeID: "I-third", title: "Third"),
    ]
    let service = service(patches: patches, nextKeys: ["fourth"])
    let context = PullRequestStackResubmissionContext(
      selectedURI: second.record.uri,
      expectedRepoCommit: "bafyrepo",
      snapshots: snapshots,
      items: Dictionary(
        uniqueKeysWithValues: snapshots.map {
          (
            $0.key,
            PullRequestListItem(record: $0.value.record, status: .open, commentCount: 0)
          )
        }
      ),
      orderedURIs: [first.record.uri, second.record.uri, third.record.uri]
    )

    let prepared = try await service.plan(
      context,
      commits: [
        commit(changeID: "I-third", title: "Third updated"),
        commit(changeID: "I-first", title: "First updated"),
        commit(changeID: "I-fourth", title: "Fourth"),
      ]
    )

    #expect(prepared.plan.requiresConfirmation)
    #expect(prepared.plan.operations.map(\.kind) == [.update, .update, .create, .delete])
    #expect(prepared.plan.operations[0].pullRequestURI == third.record.uri)
    #expect(prepared.plan.operations[0].dependentOn == nil)
    #expect(prepared.plan.operations[1].dependentOn == third.record.uri)
    #expect(
      prepared.plan.operations[2].pullRequestURI
        == "at://\(ownerDID)/sh.tangled.repo.pull/fourth"
    )
    #expect(
      prepared.plan.operations[2].dependentOn == first.record.uri
    )
    #expect(prepared.plan.operations[3].pullRequestURI == second.record.uri)
  }

  @Test func preservesMergedPullOnlyWhenItsDependencyIsUnchanged() async throws {
    let first = try snapshot(key: "first", title: "First")
    let second = try snapshot(key: "second", title: "Second", dependentOn: first.record.uri)
    let snapshots = [first.record.uri: first, second.record.uri: second]
    let service = service(
      patches: [
        first.record.uri: patch(changeID: "I-first", title: "First"),
        second.record.uri: patch(changeID: "I-second", title: "Second"),
      ],
      nextKeys: []
    )
    let context = PullRequestStackResubmissionContext(
      selectedURI: second.record.uri,
      expectedRepoCommit: "bafyrepo",
      snapshots: snapshots,
      items: [
        first.record.uri: .init(record: first.record, status: .merged, commentCount: 0),
        second.record.uri: .init(record: second.record, status: .open, commentCount: 0),
      ],
      orderedURIs: [first.record.uri, second.record.uri]
    )

    let prepared = try await service.plan(
      context,
      commits: [
        commit(changeID: "I-first", title: "Ignored merged title"),
        commit(changeID: "I-second", title: "Second updated"),
      ]
    )
    #expect(prepared.plan.operations.map(\.kind) == [.preserveMerged, .update])

    await #expect(throws: TangledError.self) {
      _ = try await service.plan(
        context,
        commits: [
          self.commit(changeID: "I-second", title: "Second"),
          self.commit(changeID: "I-first", title: "First"),
        ]
      )
    }
  }

  @Test func parsesAFormatPatchSeries() throws {
    let series =
      patch(changeID: "I-first", title: "[PATCH 1/2] First")
      + patch(changeID: "I-second", title: "[PATCH 2/2] Second")

    let commits = try FormatPatchSeries.parse(series)

    #expect(commits.map(\.title) == ["First", "Second"])
    #expect(commits.map(\.changeID) == ["I-first", "I-second"])
    #expect(commits.map(\.body) == [nil, nil])
  }

  @Test func forkCommitsUsesSourceRepositoryDIDForHiddenRef() async throws {
    let sourceRepositoryDID = "did:plc:fork"
    let targetRepositoryDID = "did:plc:repository"
    let selected = try snapshot(
      key: "selected",
      title: "Selected",
      sourceRepositoryDID: sourceRepositoryDID
    )
    let context = PullRequestStackResubmissionContext(
      selectedURI: selected.record.uri,
      expectedRepoCommit: "bafyrepo",
      snapshots: [selected.record.uri: selected],
      items: [
        selected.record.uri: .init(record: selected.record, status: .open, commentCount: 0)
      ],
      orderedURIs: [selected.record.uri]
    )
    let recorder = StackForkRecorder()
    let service = PullRequestStackResubmissionService(
      dependencies: .init(
        snapshot: { _ in throw TangledError.notFound("unused") },
        latestCommit: { _ in "bafyrepo" },
        repository: { reference in
          switch reference {
          case sourceRepositoryDID:
            return self.repository(
              ownerDID: "did:plc:fork-owner",
              repositoryDID: sourceRepositoryDID,
              source: targetRepositoryDID
            )
          case targetRepositoryDID:
            return self.repository(
              ownerDID: "did:plc:owner",
              repositoryDID: targetRepositoryDID
            )
          default:
            throw TangledError.notFound(reference)
          }
        },
        list: { _, _, _, _ in Page(items: []) },
        patch: { _ in throw TangledError.notFound("unused") },
        updateHiddenRef: { knot, token, repositoryDID, source, target in
          await recorder.recordHiddenRef([knot, token, repositoryDID, source, target])
          return "refs/hidden/feature/main"
        },
        compare: { knot, repositoryDID, base, head in
          await recorder.recordComparison([knot, repositoryDID, base, head])
          return GitComparison(
            baseRevision: "aaaaaaaa",
            headRevision: "bbbbbbbb",
            formatPatches: [self.formatPatch()],
            patch: "",
            combinedFiles: [],
            combinedPatch: ""
          )
        },
        nextRecordKey: { "unused" }
      )
    )

    let commits = try await service.forkCommits(
      context,
      pdsClient: serviceAuthPDSClient()
    )

    #expect(commits.map(\.changeID) == ["I-selected"])
    #expect(
      await recorder.hiddenRefArguments()
        == ["knot.example", "service-token", sourceRepositoryDID, "feature", "main"]
    )
    #expect(
      await recorder.comparisonArguments()
        == [
          "knot.example",
          sourceRepositoryDID,
          "refs/hidden/feature/main",
          "feature",
        ]
    )
  }

  private func service(
    patches: [String: Data],
    nextKeys: [String]
  ) -> PullRequestStackResubmissionService {
    let keys = KeySequence(nextKeys)
    return PullRequestStackResubmissionService(
      dependencies: .init(
        snapshot: { _ in throw TangledError.notFound("unused") },
        latestCommit: { _ in "bafyrepo" },
        repository: { _ in throw TangledError.notFound("unused") },
        list: { _, _, _, _ in Page(items: []) },
        patch: { record in
          guard let patch = patches[record.uri] else {
            throw TangledError.notFound(record.uri)
          }
          return patch
        },
        updateHiddenRef: { _, _, _, _, _ in "unused" },
        compare: { _, _, _, _ in
          throw TangledError.notFound("unused")
        },
        nextRecordKey: { keys.next() }
      )
    )
  }

  private func snapshot(
    key: String,
    title: String,
    dependentOn: String? = nil,
    sourceRepositoryDID: String? = nil
  ) throws -> PullRequestRecordSnapshot {
    let pull = PullRequest(
      title: title,
      rounds: [
        .init(
          createdAt: FormatString(rawValue: "2026-07-28T00:00:00Z"),
          patchBlob: .init(cid: "bafk\(key)", mimeType: "application/gzip", size: 42)
        )
      ],
      source: .init(branch: "feature", repositoryDID: sourceRepositoryDID),
      target: .init(branch: "main", repositoryDID: "did:plc:repository"),
      createdAt: FormatString(rawValue: "2026-07-28T00:00:00Z"),
      dependentOn: dependentOn
    )
    let blob = try JSONDecoder().decode(
      LexBlob.self,
      from: Data(
        """
        {"$type":"blob","ref":{"$link":"bafkreigh2akiscaildcw453ukxq2grj32w3w6v3ip5ir6v3g7h4xj5d4te"},"mimeType":"application/gzip","size":42}
        """.utf8
      )
    )
    let lexicon = Sh.Tangled.RepoPull(
      createdAt: pull.createdAt,
      dependentOn: dependentOn.map(FormatString.init(rawValue:)),
      mentions: [],
      references: [],
      rounds: [
        .init(
          createdAt: pull.rounds[0].createdAt,
          patchBlob: blob
        )
      ],
      source: .init(
        branch: "feature",
        repo: sourceRepositoryDID.map(FormatString.init(rawValue:))
      ),
      target: .init(
        branch: "main",
        repo: FormatString(rawValue: "did:plc:repository")
      ),
      title: title
    )
    return PullRequestRecordSnapshot(
      record: .init(
        uri: "at://\(ownerDID)/sh.tangled.repo.pull/\(key)",
        cid: "bafy\(key)",
        value: pull
      ),
      rawValue: .record(lexicon)
    )
  }

  private func commit(changeID: String, title: String) -> PullRequestStackCommit {
    .init(
      title: title,
      changeID: changeID,
      patch: patch(changeID: changeID, title: title)
    )
  }

  private func repository(
    ownerDID: String,
    repositoryDID: String,
    source: String? = nil
  ) -> TangledRecord<Repository> {
    TangledRecord(
      uri: "at://\(ownerDID)/sh.tangled.repo/example",
      cid: "bafyrepo",
      value: Repository(
        name: "example",
        knot: "knot.example",
        source: source,
        repoDID: repositoryDID,
        createdAt: FormatString(rawValue: "2026-07-28T00:00:00Z")
      )
    )
  }

  private func formatPatch() -> GitFormatPatch {
    GitFormatPatch(
      files: [],
      sha: "bbbbbbbb",
      author: GitSignature(
        name: "Test",
        email: "test@example.com",
        when: FormatString(rawValue: "2026-07-28T00:00:00Z")
      ),
      title: "Selected",
      body: "",
      subjectPrefix: "PATCH",
      bodyAppendix: "",
      headers: ["Change-Id": ["I-selected"]],
      raw: String(decoding: patch(changeID: "I-selected", title: "Selected"), as: UTF8.self)
    )
  }

  private func serviceAuthPDSClient() -> PDSClient {
    PDSClient(
      client: StackServiceAuthXRPCClient(),
      repoDID: ownerDID,
      authorizedScopes: ["rpc:sh.tangled.repo.hiddenRef?aud=*"]
    )
  }

  private func patch(changeID: String, title: String) -> Data {
    Data(
      """
      From 0123456789012345678901234567890123456789 Mon Sep 17 00:00:00 2001
      From: Test <test@example.com>
      Date: Tue, 28 Jul 2026 00:00:00 +0000
      Subject: \(title)
      Change-Id: \(changeID)

      ---
       file | 1 +
       1 file changed, 1 insertion(+)

      diff --git a/file b/file
      index e69de29..7898192 100644
      --- a/file
      +++ b/file
      @@ -0,0 +1 @@
      +a
      --
      2.50.0

      """.utf8
    )
  }
}

private actor StackForkRecorder {
  private var hiddenRef: [String]?
  private var comparison: [String]?

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

private struct StackServiceAuthXRPCClient: XRPCCallable {
  func getProxy(nsid _: String) -> String? { nil }

  func response(_ components: XRPCRequestComponents) async throws -> Data {
    guard components.nsId == "com.atproto.server.getServiceAuth" else {
      throw TangledError.invalidRequest("unexpected request")
    }
    return Data(#"{"token":"service-token"}"#.utf8)
  }
}

private final class KeySequence: @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [String]

  init(_ keys: [String]) {
    self.keys = keys
  }

  func next() -> String {
    lock.withLock { keys.removeFirst() }
  }
}
