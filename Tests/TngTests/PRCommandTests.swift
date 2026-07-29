import Foundation
import SwiftAtproto
import SwiftTangled
import Testing

@testable import tng

@Suite struct PRCommandTests {
  @Test func parsesListAndViewArguments() throws {
    let list = try PRListCommand.parse([
      "alice.example/core", "--author", "bob.example", "--status", "merged",
      "--limit", "25", "--cursor", "next", "--sort", "asc", "--json",
    ])
    #expect(list.repository == "alice.example/core")
    #expect(list.author == "bob.example")
    #expect(list.status == "merged")
    #expect(list.limit == 25)
    #expect(list.cursor == "next")
    #expect(list.sort == "asc")
    #expect(list.json)

    let view = try PRViewCommand.parse([samplePullRequestURI, "--json"])
    #expect(view.pullRequestURI == samplePullRequestURI)
    #expect(view.json)
    let viewComments = try PRViewCommand.parse([
      samplePullRequestURI, "--comments", "--comment-limit", "10", "--comment-cursor", "next",
    ])
    #expect(viewComments.comments)
    #expect(viewComments.commentLimit == 10)
    #expect(viewComments.commentCursor == "next")

    let comment = try PRCommentCommand.parse([
      samplePullRequestURI, "--body", "Looks good", "--round", "1", "--json",
    ])
    #expect(comment.body == "Looks good")
    #expect(comment.round == 1)
    #expect(comment.json)
    let edit = try PREditCommand.parse([
      samplePullRequestURI, "-t", "New title", "-b", "", "--json",
    ])
    #expect(edit.pullRequestURI == samplePullRequestURI)
    #expect(edit.title == "New title")
    #expect(edit.body == "")
    #expect(edit.json)
    let editFromStdin = try PREditCommand.parse([
      samplePullRequestURI, "-F", "-",
    ])
    #expect(editFromStdin.bodyFile == "-")
    #expect(throws: (any Error).self) {
      _ = try PRCommentCommand.parse([samplePullRequestURI])
    }
    #expect(throws: (any Error).self) {
      _ = try PRCommentCommand.parse([
        samplePullRequestURI, "--body", "text", "--body-file", "body.md",
      ])
    }
    #expect(throws: (any Error).self) {
      _ = try PREditCommand.parse([samplePullRequestURI])
    }
    #expect(throws: (any Error).self) {
      _ = try PREditCommand.parse([
        samplePullRequestURI, "--body", "text", "--body-file", "body.md",
      ])
    }

    let diff = try PRDiffCommand.parse([samplePullRequestURI, "--round", "0"])
    #expect(diff.pullRequestURI == samplePullRequestURI)
    #expect(diff.round == 0)
    #expect(try PRDiffCommand.parse([samplePullRequestURI]).round == nil)

    let create = try PRCreateCommand.parse([
      "--repo", "alice.example/core", "--base", "main", "--head", "feature/pr",
      "--title", "Create PR", "--body", "Details", "--json",
    ])
    #expect(create.repo == "alice.example/core")
    #expect(create.base == "main")
    #expect(create.head == "feature/pr")
    #expect(create.title == "Create PR")
    #expect(create.body == "Details")
    #expect(create.json)
    let createStack = try PRCreateCommand.parse([
      "--base", "main", "--head", "feature/stack", "--stack", "--json",
    ])
    #expect(createStack.stack)
    #expect(createStack.json)
    #expect(throws: (any Error).self) {
      _ = try PRCreateCommand.parse(["--stack", "--title", "Ambiguous"])
    }
    let resubmit = try PRResubmitCommand.parse([samplePullRequestURI, "--json"])
    #expect(resubmit.pullRequestURI == samplePullRequestURI)
    #expect(resubmit.patchFile == nil)
    #expect(resubmit.json)
    let stackResubmit = try PRResubmitCommand.parse([
      samplePullRequestURI, "--stack", "--dry-run", "--json",
    ])
    #expect(stackResubmit.stack)
    #expect(stackResubmit.dryRun)
    #expect(stackResubmit.json)
    #expect(throws: (any Error).self) {
      _ = try PRResubmitCommand.parse([
        samplePullRequestURI, "--stack", "--dry-run", "--yes",
      ])
    }

    let patchResubmit = try PRResubmitCommand.parse([
      samplePullRequestURI, "--patch-file", "changes.patch",
    ])
    #expect(patchResubmit.patchFile == "changes.patch")
    #expect(throws: (any Error).self) {
      _ = try PRCreateCommand.parse(["--body", "text", "--body-file", "body.md"])
    }

    #expect(throws: (any Error).self) {
      _ = try PRListCommand.parse(["--status", "draft"])
    }
    #expect(throws: (any Error).self) {
      _ = try PRListCommand.parse(["--limit", "0"])
    }
    #expect(throws: (any Error).self) {
      _ = try PRListCommand.parse(["--sort", "newest"])
    }
    #expect(throws: (any Error).self) {
      _ = try PRDiffCommand.parse([samplePullRequestURI, "--round", "-1"])
    }

    let merge = try PRMergeCommand.parse([
      samplePullRequestURI, "--check", "--stack", "--json",
    ])
    #expect(merge.pullRequestURI == samplePullRequestURI)
    #expect(merge.check)
    #expect(merge.stack)
    #expect(merge.json)

    let close = try PRCloseCommand.parse([samplePullRequestURI, "--json"])
    #expect(close.pullRequestURI == samplePullRequestURI)
    #expect(close.json)
    let reopen = try PRReopenCommand.parse([samplePullRequestURI])
    #expect(reopen.pullRequestURI == samplePullRequestURI)
    #expect(!reopen.json)
  }

  @Test func mergeCheckAndMergeFormatResults() async throws {
    let recorder = PRCommandRecorder()
    let service = PRCommandService(dependencies: dependencies(recorder: recorder))

    let checked = try await service.merge(
      pullRequestURI: samplePullRequestURI,
      checkOnly: true,
      allowStack: false,
      json: false
    )
    #expect(checked.stdout.contains("Mergeable\tyes"))
    #expect(checked.stdout.contains("Target\tdid:plc:repository:main"))

    let merged = try await service.merge(
      pullRequestURI: samplePullRequestURI,
      checkOnly: false,
      allowStack: true,
      json: true
    )
    #expect(merged.stdout.contains("\"pullRequestURIs\""))
    #expect(merged.stdout.contains(samplePullRequestURI))
    #expect(merged.stdout.contains("\"outcome\" : \"merged\""))
  }

  @Test func mergeFormatsPartialSuccessWithoutSuggestingRetry() async throws {
    let recorder = PRCommandRecorder()
    let partialResult = PullRequestMergeResult(
      check: PullRequestMergeCheck(
        pullRequestURIs: [samplePullRequestURI],
        repositoryDID: "did:plc:repository",
        targetBranch: "main",
        isConflicted: false
      ),
      statusRecords: [],
      outcome: .mergedStatusRecordsFailed,
      statusRecordError: "status write failed"
    )
    let service = PRCommandService(
      dependencies: dependencies(recorder: recorder, mergeResult: partialResult)
    )

    let human = try await service.merge(
      pullRequestURI: samplePullRequestURI,
      checkOnly: false,
      allowStack: false,
      json: false
    )
    let json = try await service.merge(
      pullRequestURI: samplePullRequestURI,
      checkOnly: false,
      allowStack: false,
      json: true
    )

    #expect(human.stdout.hasPrefix("Merge succeeded: \(samplePullRequestURI)\n"))
    #expect(human.stdout.contains("Merged status records were not written: status write failed"))
    #expect(human.stdout.contains("Do not rerun `tng pr merge` for \(samplePullRequestURI)"))
    #expect(json.stdout.contains("\"outcome\" : \"merged_status_records_failed\""))
    #expect(json.stdout.contains("\"statusRecordError\" : \"status write failed\""))
  }

  @Test func editUsesAuthoritativePreparedRecordAndReadsBodyFiles() async throws {
    let recorder = PRCommandRecorder()
    let service = PRCommandService(dependencies: dependencies(recorder: recorder))

    let human = try await service.edit(
      pullRequestURI: samplePullRequestURI,
      title: "Updated title",
      body: nil,
      bodyFile: "-",
      json: false
    )
    let json = try await service.edit(
      pullRequestURI: samplePullRequestURI,
      title: nil,
      body: "",
      bodyFile: nil,
      json: true
    )

    #expect(human.stdout.contains("Title\tUpdated title"))
    #expect(human.stdout.contains("Body\tFrom stdin"))
    let decoded = try JSONDecoder().decode(
      TangledRecord<PullRequest>.self,
      from: Data(json.stdout.utf8)
    )
    #expect(decoded.value.title == "Preserve rounds")
    #expect(decoded.value.body == "")
    #expect(
      await recorder.editCalls()
        == [
          .init(title: "Updated title", body: "From stdin\n"),
          .init(title: "Preserve rounds", body: ""),
        ]
    )
    #expect(await recorder.viewPullRequestURIs().isEmpty)
    #expect(
      await recorder.authoritativePullRequestURIs()
        == [samplePullRequestURI, samplePullRequestURI]
    )
  }

  @Test func editPropagatesConflictWithoutRetrying() async {
    let recorder = PRCommandRecorder()
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        editError: .conflict(nil)
      )
    )

    await #expect(throws: TangledError.self) {
      _ = try await service.edit(
        pullRequestURI: samplePullRequestURI,
        title: "Updated title",
        body: nil,
        bodyFile: nil,
        json: false
      )
    }

    #expect(await recorder.editCalls().count == 1)
    #expect(await recorder.authoritativePullRequestURIs() == [samplePullRequestURI])
  }

  @Test func closeAndReopenFormatStatusRecords() async throws {
    let recorder = PRCommandRecorder()
    let service = PRCommandService(dependencies: dependencies(recorder: recorder))

    let closed = try await service.setStatus(
      pullRequestURI: samplePullRequestURI,
      status: .closed,
      json: true
    )
    let closedRecord = try JSONDecoder().decode(
      TangledRecord<PullRequestStatusChange>.self,
      from: Data(closed.stdout.utf8)
    )
    #expect(closedRecord.value.status == .closed)
    #expect(closedRecord.value.pullRequestURI == samplePullRequestURI)

    let reopened = try await service.setStatus(
      pullRequestURI: samplePullRequestURI,
      status: .open,
      json: false
    )
    #expect(reopened.stdout.contains("Pull request\t\(samplePullRequestURI)"))
    #expect(reopened.stdout.contains("Status\topen"))
    #expect(
      await recorder.statusCalls()
        == [
          .init(uri: samplePullRequestURI, status: .closed),
          .init(uri: samplePullRequestURI, status: .open),
        ]
    )
  }

  @Test func listResolvesRepositoryAndAuthorAndFormatsPage() async throws {
    let recorder = PRCommandRecorder()
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        pullRequestRecord: samplePullRequestRecord(title: "Fix\tlogin\nflow")
      )
    )

    let output = try await service.list(
      repository: "alice.example/core",
      author: "bob.example",
      status: .merged,
      limit: 25,
      cursor: "previous",
      sort: .ascending,
      json: false
    )

    #expect(output.stdout.hasPrefix("URI\tSTATUS\tTITLE\tROUNDS\tCOMMENTS\tCREATED\n"))
    #expect(output.stdout.contains("\tmerged\tFix login flow\t2\t-\t"))
    #expect(output.stderr == "Next cursor: next-page\n")
    #expect(await recorder.references() == ["alice.example/core"])
    #expect(await recorder.owners() == ["bob.example"])
    #expect(
      await recorder.authorListCalls()
        == [
          .init(
            repositoryDID: "did:plc:repository",
            repositoryOwnerDID: "did:plc:owner",
            authorDID: "did:plc:resolved-author",
            status: .merged,
            cursor: "previous",
            limit: 25,
            order: .ascending
          )
        ]
    )
    #expect(await recorder.listCalls().isEmpty)
  }

  @Test func listUsesOriginFallbackAndPreservesPageJSON() async throws {
    let recorder = PRCommandRecorder()
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        originURL: { "git@tangled.org:alice.example/core.git" }
      )
    )

    let output = try await service.list(
      repository: nil,
      author: nil,
      status: nil,
      limit: 30,
      cursor: nil,
      json: true
    )

    let page = try JSONDecoder().decode(
      Page<PullRequestListItem>.self,
      from: Data(output.stdout.utf8)
    )
    #expect(page.cursor == "next-page")
    #expect(page.items.first?.record.uri == samplePullRequestURI)
    #expect(output.stderr.isEmpty)
    #expect(await recorder.references() == ["git@tangled.org:alice.example/core.git"])
  }

  @Test func viewFormatsEveryRoundAndPreservesRecordJSON() async throws {
    let recorder = PRCommandRecorder()
    let service = PRCommandService(dependencies: dependencies(recorder: recorder))

    let human = try await service.view(pullRequestURI: samplePullRequestURI, json: false)
    let json = try await service.view(pullRequestURI: samplePullRequestURI, json: true)

    #expect(human.stdout.contains("Title\tPreserve rounds"))
    #expect(human.stdout.contains("Source branch\tfeature/rounds"))
    #expect(human.stdout.contains("Target repository DID\tdid:plc:repository"))
    #expect(human.stdout.contains("Rounds\t2"))
    #expect(human.stdout.contains("Round 0 patch CID\tbafkroundone"))
    #expect(human.stdout.contains("Round 1 patch MIME type\tapplication/gzip"))
    #expect(human.stdout.contains("Round 1 patch size\t2012"))
    #expect(human.isPageable)
    #expect(!json.isPageable)
    let record = try JSONDecoder().decode(
      TangledRecord<PullRequest>.self,
      from: Data(json.stdout.utf8)
    )
    #expect(record.uri == samplePullRequestURI)
    #expect(record.value.rounds.count == 2)
    #expect(await recorder.pullRequestURIs() == [samplePullRequestURI, samplePullRequestURI])
  }

  @Test func viewCanIncludeCommentsAndCursor() async throws {
    let recorder = PRCommandRecorder()
    let service = PRCommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.view(
      pullRequestURI: samplePullRequestURI,
      comments: true,
      commentLimit: 10,
      commentCursor: "previous",
      json: true
    )

    let result = try JSONDecoder().decode(
      PRViewWithCommentsResult.self,
      from: Data(output.stdout.utf8)
    )
    #expect(result.pullRequest.uri == samplePullRequestURI)
    #expect(result.comments.items.first?.value.body.markdown?.text == "Review comment")
    #expect(result.comments.cursor == "comment-next")
    #expect(!output.isPageable)
  }

  @Test func commentDefaultsToLatestRound() async throws {
    let recorder = PRCommandRecorder()
    let service = PRCommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.comment(
      pullRequestURI: samplePullRequestURI,
      body: "Review comment",
      bodyFile: nil,
      roundNumber: nil,
      json: true
    )

    let object = try #require(
      JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any]
    )
    let value = try #require(object["value"] as? [String: Any])
    let context = try #require(value["context"] as? [String: Any])
    let body = try #require(value["body"] as? [String: Any])
    #expect(context["pullRequestRoundIndex"] as? Int == 1)
    #expect(body["text"] as? String == "Review comment")
  }

  @Test func viewAndCommentUseSeparatePullRequestReads() async throws {
    let recorder = PRCommandRecorder()
    let viewRecord = samplePullRequestRecord(title: "Indexed view")
    let authoritativeRecord = samplePullRequestRecord(title: "Authoritative comment")
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        viewPullRequestRecord: viewRecord,
        authoritativePullRequestRecord: authoritativeRecord
      )
    )

    let viewed = try await service.view(
      pullRequestURI: samplePullRequestURI,
      json: false
    )
    _ = try await service.comment(
      pullRequestURI: samplePullRequestURI,
      body: "Latest round",
      bodyFile: nil,
      roundNumber: nil,
      json: false
    )

    #expect(viewed.stdout.contains("Title\tIndexed view"))
    #expect(await recorder.viewPullRequestURIs() == [samplePullRequestURI])
    #expect(await recorder.authoritativePullRequestURIs() == [samplePullRequestURI])
  }

  @Test func commentDoesNotWriteWhenAuthoritativeReadFails() async {
    let recorder = PRCommandRecorder()
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        authoritativePullRequestError: .notFound("not indexed in PDS")
      )
    )

    await #expect(throws: TangledError.self) {
      _ = try await service.comment(
        pullRequestURI: samplePullRequestURI,
        body: "Must not be written",
        bodyFile: nil,
        roundNumber: nil,
        json: false
      )
    }

    #expect(await recorder.commentWriteCount() == 0)
  }

  @Test func listRejectsRepositoryWithoutRepositoryDID() async {
    let recorder = PRCommandRecorder()
    let repository = sampleRepositoryRecord(repositoryDID: nil)
    let service = PRCommandService(
      dependencies: dependencies(recorder: recorder, repositoryRecord: repository)
    )

    await #expect(throws: TangledError.self) {
      _ = try await service.list(
        repository: "alice.example/core",
        author: nil,
        status: nil,
        limit: 30,
        cursor: nil,
        json: false
      )
    }
    #expect(await recorder.listCalls().isEmpty)
  }

  @Test func diffWritesUnifiedDiffBytesWithoutDecoration() async throws {
    let recorder = PRCommandRecorder()
    let service = PRCommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.diff(
      pullRequestURI: samplePullRequestURI,
      roundNumber: 0
    )

    #expect(output.stdoutData == samplePullRequestPatch().unifiedDiff)
    #expect(output.stderr.isEmpty)
    #expect(output.isPageable)
    #expect(
      await recorder.patchCalls() == [
        .init(uri: samplePullRequestURI, roundNumber: 0)
      ])
  }

  @Test func createUsesOriginDefaultsAndFormatsCanonicalLocations() async throws {
    let recorder = PRCommandRecorder()
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        originURL: { "git@tangled.org:alice.example/core.git" }
      )
    )

    let output = try await service.create(
      repository: nil,
      base: nil,
      head: nil,
      title: nil,
      body: nil,
      bodyFile: nil,
      json: false
    )

    #expect(output.stdout.contains("Created pull request: \(samplePullRequestURI)"))
    #expect(output.stdout.contains("https://tangled.org/did:plc:owner/core/pulls"))
    #expect(await recorder.references() == ["git@tangled.org:alice.example/core.git"])
  }

  @Test func createStackFormatsEveryPullAndPreservesForkSource() async throws {
    let recorder = PRCommandRecorder()
    let origin = "git@tangled.org:norikey.example/core.git"
    let targetReference = "alice.example/core"
    let target = sampleRepositoryRecord(repositoryDID: "did:plc:target")
    let fork = sampleRepositoryRecord(
      repositoryDID: "did:plc:fork",
      ownerDID: "did:plc:fork-owner",
      source: "did:plc:target"
    )
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        resolvedRepositories: [
          origin: fork,
          targetReference: target,
          "did:plc:target": target,
        ],
        originURL: { origin }
      )
    )

    let output = try await service.create(
      repository: targetReference,
      base: "main",
      head: "feature/stack",
      title: nil,
      body: nil,
      bodyFile: nil,
      stack: true,
      json: false
    )

    #expect(output.stdout.contains("Created 2 pull requests:"))
    #expect(output.stdout.contains("3stack1 (depends on"))
    let call = try #require(await recorder.createStackCalls().first)
    #expect(call.sourceRepositoryDID == "did:plc:fork")
    #expect(call.commits.map(\.changeID) == ["first-change", "second-change"])
    #expect(await recorder.createCalls().isEmpty)
  }

  @Test func resubmitUsesRecordBranchesAndFormatsNewRound() async throws {
    let recorder = PRCommandRecorder()
    let branchPull = samplePullRequestRecord(
      source: PullRequestSource(branch: "feature/rounds"),
      dependentOn: nil
    )
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        authoritativePullRequestRecord: branchPull,
        originURL: { "git@tangled.org:alice.example/core.git" }
      )
    )

    let output = try await service.resubmit(
      pullRequestURI: samplePullRequestURI,
      json: false
    )

    #expect(output.stdout == "Resubmitted pull request: \(samplePullRequestURI)\nRound: 2\n")
    #expect(
      await recorder.resubmitCalls()
        == [
          .init(
            patch: Data("patch".utf8),
            sourceRevision: "1111111111111111111111111111111111111111"
          )
        ]
    )
  }

  @Test func resubmitRejectsMismatchedGitOriginBeforePreparingPatch() async {
    let recorder = PRCommandRecorder()
    let branchPull = samplePullRequestRecord(
      source: PullRequestSource(branch: "feature/rounds"),
      dependentOn: nil
    )
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        repositoryRecord: sampleRepositoryRecord(repositoryDID: "did:plc:other"),
        authoritativePullRequestRecord: branchPull,
        originURL: { "git@tangled.org:other.example/core.git" }
      )
    )

    await #expect(throws: TangledError.self) {
      _ = try await service.resubmit(
        pullRequestURI: samplePullRequestURI,
        json: false
      )
    }
    #expect(await recorder.resubmitCalls().isEmpty)
  }

  @Test func resubmitForkUsesSourceOriginWithoutPreparingLocalPatch() async throws {
    let recorder = PRCommandRecorder()
    let forkPull = samplePullRequestRecord(
      source: PullRequestSource(
        branch: "feature/rounds",
        repositoryDID: "did:plc:fork"
      ),
      dependentOn: nil
    )
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        repositoryRecord: sampleRepositoryRecord(repositoryDID: "did:plc:fork"),
        authoritativePullRequestRecord: forkPull,
        originURL: { "git@tangled.org:fork.example/core.git" }
      )
    )

    let output = try await service.resubmit(
      pullRequestURI: samplePullRequestURI,
      json: false
    )

    #expect(output.stdout.contains("Round: 2"))
    #expect(await recorder.forkResubmitCount() == 1)
    #expect(await recorder.resubmitCalls().isEmpty)
  }

  @Test func resubmitForkRejectsMismatchedSourceOrigin() async {
    let recorder = PRCommandRecorder()
    let forkPull = samplePullRequestRecord(
      source: PullRequestSource(
        branch: "feature/rounds",
        repositoryDID: "did:plc:fork"
      ),
      dependentOn: nil
    )
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        repositoryRecord: sampleRepositoryRecord(repositoryDID: "did:plc:other"),
        authoritativePullRequestRecord: forkPull,
        originURL: { "git@tangled.org:other.example/core.git" }
      )
    )

    await #expect(throws: TangledError.self) {
      _ = try await service.resubmit(
        pullRequestURI: samplePullRequestURI,
        json: false
      )
    }
    #expect(await recorder.forkResubmitCount() == 0)
  }

  @Test func resubmitPatchReadsFileWithoutUsingGit() async throws {
    let recorder = PRCommandRecorder()
    let patchRecord = samplePullRequestRecord(source: nil, dependentOn: nil)
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        authoritativePullRequestRecord: patchRecord,
        originURL: { throw TangledError.invalidRequest("Git must not be used") }
      )
    )
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let patch = Data("diff --git a/a b/a\n--- a/a\n+++ b/a\n".utf8)
    try patch.write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let output = try await service.resubmit(
      pullRequestURI: samplePullRequestURI,
      patchFile: fileURL.path,
      json: false
    )

    #expect(output.stdout.contains("Round: 2"))
    #expect(await recorder.resubmitCalls() == [.init(patch: patch, sourceRevision: nil)])
  }

  @Test func patchFileReaderRejectsDirectoryAndSymbolicLink() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("patch")
    let link = directory.appendingPathComponent("patch-link")
    try Data("diff --git a/a b/a\n--- a/a\n".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(throws: TangledError.self) {
      _ = try PatchFileReader().read(path: directory.path)
    }
    #expect(throws: TangledError.self) {
      _ = try PatchFileReader().read(path: link.path)
    }
  }

  @Test func createURLFallsBackToRepositoryRkeyWhenNameIsMissing() async throws {
    let recorder = PRCommandRecorder()
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        repositoryRecord: sampleRepositoryRecord(name: nil),
        originURL: { "git@tangled.org:did:plc:repository" }
      )
    )

    let output = try await service.create(
      repository: nil,
      base: "main",
      head: "feature",
      title: "Create PR",
      body: nil,
      bodyFile: nil,
      json: false
    )

    #expect(
      output.stdout.contains(
        "https://tangled.org/did:plc:owner/core/pulls"
      )
    )
  }

  @Test func createFromForkResolvesMetadataAndPassesSourceRepositoryDID() async throws {
    let recorder = PRCommandRecorder()
    let origin = "git@tangled.org:norikey.example/core.git"
    let targetReference = "alice.example/core"
    let target = sampleRepositoryRecord(repositoryDID: "did:plc:target")
    let fork = sampleRepositoryRecord(
      repositoryDID: "did:plc:fork",
      ownerDID: "did:plc:fork-owner",
      source: "did:plc:target"
    )
    let service = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        resolvedRepositories: [
          origin: fork,
          targetReference: target,
          "did:plc:target": target,
        ],
        originURL: { origin }
      )
    )

    _ = try await service.create(
      repository: targetReference,
      base: "main",
      head: "main",
      title: "Fork pull request",
      body: nil,
      bodyFile: nil,
      json: true
    )

    #expect(
      await recorder.createCalls().first?.sourceRepositoryDID == "did:plc:fork"
    )
    #expect(await recorder.createCalls().first?.targetRepositoryDID == "did:plc:target")
  }

  @Test func createFromForkRejectsMissingOrMismatchedMetadata() async throws {
    let recorder = PRCommandRecorder()
    let origin = "git@tangled.org:norikey.example/core.git"
    let targetReference = "alice.example/core"
    let target = sampleRepositoryRecord(repositoryDID: "did:plc:target")
    let unrelated = sampleRepositoryRecord(repositoryDID: "did:plc:unrelated")

    let missing = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        resolvedRepositories: [
          origin: sampleRepositoryRecord(repositoryDID: "did:plc:fork"),
          targetReference: target,
        ],
        originURL: { origin }
      )
    )
    await #expect(throws: TangledError.self) {
      _ = try await missing.create(
        repository: targetReference,
        base: "main",
        head: "feature",
        title: "Title",
        body: nil,
        bodyFile: nil,
        json: false
      )
    }

    let mismatched = PRCommandService(
      dependencies: dependencies(
        recorder: recorder,
        resolvedRepositories: [
          origin: sampleRepositoryRecord(
            repositoryDID: "did:plc:fork",
            source: "did:plc:unrelated"
          ),
          targetReference: target,
          "did:plc:unrelated": unrelated,
        ],
        originURL: { origin }
      )
    )
    await #expect(throws: TangledError.self) {
      _ = try await mismatched.create(
        repository: targetReference,
        base: "main",
        head: "feature",
        title: "Title",
        body: nil,
        bodyFile: nil,
        json: false
      )
    }
    #expect(await recorder.createCalls().isEmpty)
  }

  @Test func gitPreparerRequiresPushedHeadAndBuildsFormatPatch() throws {
    let localHead = "1111111111111111111111111111111111111111"
    let baseHead = "2222222222222222222222222222222222222222"
    let preparer = GitPullRequestPreparer { arguments in
      switch arguments {
      case ["symbolic-ref", "--quiet", "--short", "HEAD"]:
        return Data("feature/pr\n".utf8)
      case ["rev-parse", "--verify", "refs/heads/feature/pr"]:
        return Data("\(localHead)\n".utf8)
      case ["ls-remote", "--heads", "origin", "refs/heads/feature/pr"]:
        return Data("\(localHead)\trefs/heads/feature/pr\n".utf8)
      case ["ls-remote", "--heads", "origin", "refs/heads/main"]:
        return Data("\(baseHead)\trefs/heads/main\n".utf8)
      case ["cat-file", "-e", "\(baseHead)^{commit}"]:
        return Data()
      case ["log", "--reverse", "--format=%s%x00%b%x00", "\(baseHead)..\(localHead)"]:
        return Data("First subject\0First body\0".utf8)
      case ["format-patch", "--stdout", "--binary", "\(baseHead)..\(localHead)"]:
        return Data("From \(localHead)\n".utf8)
      default:
        throw CLICommandError.git("unexpected command: \(arguments)")
      }
    }

    let result = try preparer.prepare(base: "main", head: nil)

    #expect(result.head == "feature/pr")
    #expect(result.title == "First subject")
    #expect(result.body == "First body")
    #expect(result.patch == Data("From \(localHead)\n".utf8))
  }

  @Test func gitPreparerBuildsOrderedStackFromChangeIDHeaders() throws {
    let first = "1111111111111111111111111111111111111111"
    let second = "2222222222222222222222222222222222222222"
    let base = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let firstPatch = """
      From \(first) Mon Sep 17 00:00:00 2001
      From: Test <test@example.com>
      Subject: [PATCH] First
      Change-Id: change-one

      diff --git a/one b/one
      --- a/one
      +++ b/one
      @@ -0,0 +1 @@
      +one
      """
    let secondPatch = """
      From \(second) Mon Sep 17 00:00:00 2001
      From: Test <test@example.com>
      Subject: [PATCH] Second
      Change-Id: change-two

      diff --git a/two b/two
      --- a/two
      +++ b/two
      @@ -0,0 +1 @@
      +two
      """
    let preparer = GitPullRequestPreparer { arguments in
      switch arguments {
      case ["rev-parse", "--verify", "refs/heads/feature/stack"]:
        return Data("\(second)\n".utf8)
      case ["ls-remote", "--heads", "origin", "refs/heads/feature/stack"]:
        return Data("\(second)\trefs/heads/feature/stack\n".utf8)
      case ["ls-remote", "--heads", "origin", "refs/heads/main"]:
        return Data("\(base)\trefs/heads/main\n".utf8)
      case ["cat-file", "-e", "\(base)^{commit}"]:
        return Data()
      case ["log", "-z", "--reverse", "--format=%H%x00%s%x00%b", "\(base)..\(second)"]:
        return Data("\(first)\0First title\0First body\0\(second)\0Second title\0\0".utf8)
      case ["cat-file", "commit", first]:
        return Data("tree a\nchange-id change-one\n\nFirst title\n".utf8)
      case ["cat-file", "commit", second]:
        return Data("tree b\nchange-id change-two\n\nSecond title\n".utf8)
      case [
        "format-patch", "--stdout", "--binary", "--no-cover-letter", "-1", first,
        "--add-header", "Change-Id: change-one",
      ]:
        return Data("\(firstPatch)\n".utf8)
      case [
        "format-patch", "--stdout", "--binary", "--no-cover-letter", "-1", second,
        "--add-header", "Change-Id: change-two",
      ]:
        return Data("\(secondPatch)\n".utf8)
      default:
        throw CLICommandError.git("unexpected command: \(arguments)")
      }
    }

    let result = try preparer.prepareStack(base: "main", head: "feature/stack")

    #expect(result.commits.map(\.title) == ["First title", "Second title"])
    #expect(result.commits.map(\.changeID) == ["change-one", "change-two"])
    #expect(result.commits[0].body == "First body")
    #expect(result.commits[1].body == nil)
    #expect(String(decoding: result.commits[0].patch, as: UTF8.self).contains("Change-Id: change-one"))
    #expect(String(decoding: result.commits[1].patch, as: UTF8.self).hasPrefix("From \(second)"))
  }

  @Test func gitPreparerUsesTargetRemoteForForkBase() throws {
    let localHead = "1111111111111111111111111111111111111111"
    let baseHead = "2222222222222222222222222222222222222222"
    let target = "https://knot1.tangled.sh/did:plc:repository/"
    let preparer = GitPullRequestPreparer { arguments in
      switch arguments {
      case ["rev-parse", "--verify", "refs/heads/main"]:
        return Data("\(localHead)\n".utf8)
      case ["ls-remote", "--heads", "origin", "refs/heads/main"]:
        return Data("\(localHead)\trefs/heads/main\n".utf8)
      case ["ls-remote", "--heads", target, "refs/heads/main"]:
        return Data("\(baseHead)\trefs/heads/main\n".utf8)
      case ["cat-file", "-e", "\(baseHead)^{commit}"]:
        return Data()
      case ["log", "--reverse", "--format=%s%x00%b%x00", "\(baseHead)..\(localHead)"]:
        return Data("Fork subject\0\0".utf8)
      case ["format-patch", "--stdout", "--binary", "\(baseHead)..\(localHead)"]:
        return Data("From fork\n".utf8)
      default:
        throw CLICommandError.git("unexpected command: \(arguments)")
      }
    }

    let result = try preparer.prepare(base: "main", head: "main", baseRemote: target)

    #expect(result.base == "main")
    #expect(result.head == "main")
    #expect(result.title == "Fork subject")
  }

  @Test func repositoryGitURLUsesKnotAndRepositoryDID() throws {
    let service = PRCommandService(dependencies: dependencies(recorder: PRCommandRecorder()))

    let url = try service.repositoryGitURL(record: sampleRepositoryRecord())

    #expect(url == "https://knot1.tangled.sh/did:plc:repository/")
  }
}

extension PRCommandTests {
  fileprivate func dependencies(
    recorder: PRCommandRecorder,
    repositoryRecord: TangledRecord<Repository>? = nil,
    pullRequestRecord: TangledRecord<PullRequest>? = nil,
    viewPullRequestRecord: TangledRecord<PullRequest>? = nil,
    authoritativePullRequestRecord: TangledRecord<PullRequest>? = nil,
    authoritativePullRequestError: TangledError? = nil,
    editError: TangledError? = nil,
    mergeResult: PullRequestMergeResult? = nil,
    resolvedRepositories: [String: TangledRecord<Repository>] = [:],
    originURL: @escaping @Sendable () throws -> String = { "unused" }
  ) -> PRCommandDependencies {
    let repositoryRecord = repositoryRecord ?? sampleRepositoryRecord()
    let pullRequestRecord = pullRequestRecord ?? samplePullRequestRecord()
    let viewPullRequestRecord = viewPullRequestRecord ?? pullRequestRecord
    let authoritativePullRequestRecord = authoritativePullRequestRecord ?? pullRequestRecord
    return PRCommandDependencies(
      resolveRepository: { reference in
        await recorder.record(reference: reference)
        return resolvedRepositories[reference] ?? repositoryRecord
      },
      resolveOwnerDID: { owner in
        await recorder.record(owner: owner)
        return owner.hasPrefix("did:") ? owner : "did:plc:resolved-author"
      },
      pullRequests: { repositoryDID, authorDID, status, cursor, limit, order in
        await recorder.record(
          list: .init(
            repositoryDID: repositoryDID,
            authorDID: authorDID,
            status: status,
            cursor: cursor,
            limit: limit,
            order: order
          )
        )
        return Page(
          items: [
            PullRequestListItem(
              record: pullRequestRecord,
              status: status ?? .open,
              commentCount: 4
            )
          ],
          cursor: "next-page"
        )
      },
      authorPullRequests: {
        repositoryDID, repositoryOwnerDID, authorDID, status, cursor, limit, order in
        await recorder.record(
          authorList: .init(
            repositoryDID: repositoryDID,
            repositoryOwnerDID: repositoryOwnerDID,
            authorDID: authorDID,
            status: status,
            cursor: cursor,
            limit: limit,
            order: order
          )
        )
        return Page(
          items: [
            PullRequestListItem(
              record: pullRequestRecord,
              status: status ?? .open,
              commentCount: -1
            )
          ],
          cursor: "next-page"
        )
      },
      viewPullRequest: { uri in
        await recorder.record(viewPullRequestURI: uri)
        return viewPullRequestRecord
      },
      authoritativePullRequest: { uri in
        await recorder.record(authoritativePullRequestURI: uri)
        if let authoritativePullRequestError {
          throw authoritativePullRequestError
        }
        return authoritativePullRequestRecord
      },
      comments: { uri, _, _ in
        Page(
          items: [
            TangledRecord(
              uri: "at://did:plc:reviewer/sh.tangled.feed.comment/3comment",
              cid: "bafycomment",
              value: Comment(
                context: .init(
                  subject: .init(uri: uri, cid: pullRequestRecord.cid ?? "")
                ),
                body: .init(text: "Review comment"),
                createdAt: FormatString<Date>(rawValue: "2026-07-24T10:00:00Z")
              )
            )
          ],
          cursor: "comment-next"
        )
      },
      coverage: {
        BobbinCoverage(ready: true, eventsProcessed: 100, lastCursor: 100)
      },
      pullRequestPatch: { uri, roundNumber in
        await recorder.record(patchURI: uri, roundNumber: roundNumber)
        return samplePullRequestPatch(roundNumber: roundNumber ?? 1)
      },
      originURL: originURL,
      defaultBranch: { _ in
        GitDefaultBranch(
          name: "main",
          hash: "abc",
          when: FormatString<Date>(rawValue: "2026-07-20T17:44:38Z")
        )
      },
      prepare: { base, head, _ in
        PreparedPullRequest(
          base: base,
          head: head ?? "feature",
          sourceRevision: "1111111111111111111111111111111111111111",
          title: "Commit title",
          body: "Commit body",
          patch: Data("patch".utf8)
        )
      },
      prepareStack: { base, head, _ in
        PreparedPullRequestStack(
          base: base,
          head: head ?? "feature",
          sourceRevision: "2222222222222222222222222222222222222222",
          commits: [
            PullRequestStackCommit(
              title: "First commit",
              changeID: "first-change",
              patch: Data("first patch".utf8)
            ),
            PullRequestStackCommit(
              title: "Second commit",
              body: "Second body",
              changeID: "second-change",
              patch: Data("second patch".utf8)
            ),
          ]
        )
      },
      create: { targetDID, sourceDID, base, head, title, body, patch in
        await recorder.record(
          create: .init(
            targetRepositoryDID: targetDID,
            sourceRepositoryDID: sourceDID,
            base: base,
            head: head,
            title: title,
            body: body,
            patch: patch
          )
        )
        return pullRequestRecord
      },
      createStack: { targetDID, sourceDID, base, head, commits in
        await recorder.record(
          createStack: .init(
            targetRepositoryDID: targetDID,
            sourceRepositoryDID: sourceDID,
            base: base,
            head: head,
            commits: commits
          )
        )
        let owner = "did:plc:author"
        let uris = commits.indices.map {
          "at://\(owner)/sh.tangled.repo.pull/3stack\($0)"
        }
        return PullRequestStackCreationResult(
          pullRequests: commits.indices.map { index in
            TangledRecord(
              uri: uris[index],
              cid: "bafystack\(index)",
              value: PullRequest(
                title: commits[index].title,
                body: commits[index].body,
                rounds: [pullRequestRecord.value.rounds[0]],
                source: PullRequestSource(branch: head, repositoryDID: sourceDID),
                target: PullRequestTarget(branch: base, repositoryDID: targetDID),
                createdAt: FormatString<Date>(rawValue: "2026-07-24T10:00:00Z"),
                dependentOn: index == 0 ? nil : uris[index - 1]
              )
            )
          }
        )
      },
      prepareEdit: { uri in
        await recorder.record(authoritativePullRequestURI: uri)
        return PreparedPREdit(
          pullRequest: authoritativePullRequestRecord,
          apply: { title, body in
            await recorder.record(edit: .init(title: title, body: body))
            if let editError {
              throw editError
            }
            return TangledRecord(
              uri: authoritativePullRequestRecord.uri,
              cid: "bafyedited",
              value: PullRequest(
                title: title,
                body: body,
                rounds: authoritativePullRequestRecord.value.rounds,
                source: authoritativePullRequestRecord.value.source,
                target: authoritativePullRequestRecord.value.target,
                createdAt: authoritativePullRequestRecord.value.createdAt,
                mentions: authoritativePullRequestRecord.value.mentions,
                references: authoritativePullRequestRecord.value.references,
                dependentOn: authoritativePullRequestRecord.value.dependentOn
              )
            )
          }
        )
      },
      readEditBodyFile: { path in
        path == "-" ? "From stdin\n" : "From file\n"
      },
      prepareResubmission: { _ in
        PreparedPRResubmission(
          pullRequest: authoritativePullRequestRecord,
          submitBranch: { patch, sourceRevision in
            await recorder.record(
              resubmit: .init(
                patch: patch,
                sourceRevision: sourceRevision
              )
            )
            return PullRequestResubmissionResult(
              pullRequest: TangledRecord(
                uri: authoritativePullRequestRecord.uri,
                cid: "bafyresubmitted",
                value: authoritativePullRequestRecord.value
              ),
              roundNumber: authoritativePullRequestRecord.value.rounds.count
            )
          },
          submitPatch: { patch in
            await recorder.record(
              resubmit: .init(
                patch: patch,
                sourceRevision: nil
              )
            )
            return PullRequestResubmissionResult(
              pullRequest: TangledRecord(
                uri: authoritativePullRequestRecord.uri,
                cid: "bafyresubmitted",
                value: authoritativePullRequestRecord.value
              ),
              roundNumber: authoritativePullRequestRecord.value.rounds.count
            )
          },
          submitFork: {
            await recorder.recordForkResubmit()
            return PullRequestResubmissionResult(
              pullRequest: TangledRecord(
                uri: authoritativePullRequestRecord.uri,
                cid: "bafyresubmitted",
                value: authoritativePullRequestRecord.value
              ),
              roundNumber: authoritativePullRequestRecord.value.rounds.count
            )
          }
        )
      },
      prepareStackResubmission: { _ in
        PreparedPRStackResubmission(
          pullRequest: authoritativePullRequestRecord,
          forkCommits: { [] },
          makePlan: { _ in
            let plan = PullRequestStackResubmissionPlan(
              selectedPullRequestURI: authoritativePullRequestRecord.uri,
              operations: []
            )
            return PreparedPRStackPlan(
              plan: plan,
              apply: {
                PullRequestStackResubmissionResult(
                  plan: plan,
                  pullRequests: [],
                  deletedPullRequestURIs: []
                )
              }
            )
          }
        )
      },
      createComment: { subject, body, roundIndex in
        await recorder.recordCommentWrite()
        return TangledRecord(
          uri: "at://did:plc:reviewer/sh.tangled.feed.comment/3comment",
          cid: "bafycomment",
          value: Comment(
            context: .init(subject: subject, pullRequestRoundIndex: roundIndex),
            body: .init(text: body),
            createdAt: FormatString<Date>(rawValue: "2026-07-24T10:00:00Z")
          )
        )
      },
      mergeCheck: { uri in
        PullRequestMergeCheck(
          pullRequestURIs: [uri],
          repositoryDID: "did:plc:repository",
          targetBranch: "main",
          isConflicted: false
        )
      },
      merge: { uri, _ in
        mergeResult
          ?? PullRequestMergeResult(
            check: PullRequestMergeCheck(
              pullRequestURIs: [uri],
              repositoryDID: "did:plc:repository",
              targetBranch: "main",
              isConflicted: false
            ),
            statusRecords: []
          )
      },
      setStatus: { uri, status in
        await recorder.record(statusURI: uri, status: status)
        return TangledRecord(
          uri: "at://did:plc:author/sh.tangled.repo.pull.status/3status",
          cid: "bafystatus",
          value: PullRequestStatusChange(
            pullRequestURI: uri,
            status: status,
            createdAt: FormatString<Date>(rawValue: "2026-07-24T10:00:00Z")
          )
        )
      }
    )
  }

  fileprivate func sampleRepositoryRecord(
    repositoryDID: String? = "did:plc:repository",
    name: String? = "core",
    ownerDID: String = "did:plc:owner",
    source: String? = nil
  ) -> TangledRecord<Repository> {
    TangledRecord(
      uri: "at://\(ownerDID)/sh.tangled.repo/core",
      value: Repository(
        name: name,
        knot: "knot1.tangled.sh",
        source: source,
        repoDID: repositoryDID,
        createdAt: FormatString<Date>(rawValue: "2026-07-20T17:44:38Z")
      )
    )
  }

  fileprivate func samplePullRequestRecord(
    title: String = "Preserve rounds",
    source: PullRequestSource? = PullRequestSource(
      branch: "feature/rounds",
      repositoryDID: "did:plc:source"
    ),
    dependentOn: String? = "at://did:plc:author/sh.tangled.repo.pull/dependency"
  ) -> TangledRecord<PullRequest> {
    TangledRecord(
      uri: samplePullRequestURI,
      cid: "bafypull",
      value: PullRequest(
        title: title,
        body: "Expose every round",
        rounds: [
          PullRequestRound(
            createdAt: FormatString<Date>(rawValue: "2026-07-20T18:00:00Z"),
            patchBlob: BlobReference(
              cid: "bafkroundone",
              mimeType: "application/gzip",
              size: 1751
            )
          ),
          PullRequestRound(
            createdAt: FormatString<Date>(rawValue: "2026-07-21T07:00:00Z"),
            patchBlob: BlobReference(
              cid: "bafkroundtwo",
              mimeType: "application/gzip",
              size: 2012
            )
          ),
        ],
        source: source,
        target: PullRequestTarget(
          branch: "main",
          repositoryDID: "did:plc:repository"
        ),
        createdAt: FormatString<Date>(rawValue: "2026-07-20T17:27:07Z"),
        mentions: ["did:plc:mentioned"],
        references: ["at://did:plc:author/sh.tangled.repo.issue/related"],
        dependentOn: dependentOn
      )
    )
  }

  fileprivate func samplePullRequestPatch(roundNumber: Int = 1) -> PullRequestPatch {
    PullRequestPatch(
      pullRequestURI: samplePullRequestURI,
      roundNumber: roundNumber,
      totalRounds: 2,
      createdAt: FormatString<Date>(rawValue: "2026-07-21T07:00:00Z"),
      blob: BlobReference(
        cid: "bafkroundtwo",
        mimeType: "application/gzip",
        size: 2012
      ),
      rawPatch: Data("Subject: [PATCH]\n\ndiff --git a/a b/a\n".utf8),
      unifiedDiff: Data("diff --git a/a b/a\n".utf8)
    )
  }
}

private let samplePullRequestURI =
  "at://did:plc:author/sh.tangled.repo.pull/3mr3itrannf22"

private actor PRCommandRecorder {
  struct ListCall: Equatable, Sendable {
    let repositoryDID: String
    let authorDID: String?
    let status: PullRequestStatus?
    let cursor: String?
    let limit: Int
    let order: BobbinSortOrder
  }

  struct AuthorListCall: Equatable, Sendable {
    let repositoryDID: String
    let repositoryOwnerDID: String
    let authorDID: String
    let status: PullRequestStatus?
    let cursor: String?
    let limit: Int
    let order: BobbinSortOrder
  }

  struct PatchCall: Equatable, Sendable {
    let uri: String
    let roundNumber: Int?
  }

  struct CreateCall: Equatable, Sendable {
    let targetRepositoryDID: String
    let sourceRepositoryDID: String?
    let base: String
    let head: String
    let title: String
    let body: String?
    let patch: Data
  }

  struct CreateStackCall: Equatable, Sendable {
    let targetRepositoryDID: String
    let sourceRepositoryDID: String?
    let base: String
    let head: String
    let commits: [PullRequestStackCommit]
  }

  struct StatusCall: Equatable, Sendable {
    let uri: String
    let status: PullRequestStatus
  }

  struct EditCall: Equatable, Sendable {
    let title: String
    let body: String?
  }

  struct ResubmitCall: Equatable, Sendable {
    let patch: Data
    let sourceRevision: String?
  }

  private var recordedReferences: [String] = []
  private var recordedOwners: [String] = []
  private var recordedListCalls: [ListCall] = []
  private var recordedAuthorListCalls: [AuthorListCall] = []
  private var recordedViewPullRequestURIs: [String] = []
  private var recordedAuthoritativePullRequestURIs: [String] = []
  private var recordedPatchCalls: [PatchCall] = []
  private var recordedCreateCalls: [CreateCall] = []
  private var recordedCreateStackCalls: [CreateStackCall] = []
  private var recordedStatusCalls: [StatusCall] = []
  private var recordedEditCalls: [EditCall] = []
  private var recordedResubmitCalls: [ResubmitCall] = []
  private var recordedForkResubmitCount = 0
  private var recordedCommentWriteCount = 0

  func record(reference: String) {
    recordedReferences.append(reference)
  }

  func record(owner: String) {
    recordedOwners.append(owner)
  }

  func record(list: ListCall) {
    recordedListCalls.append(list)
  }

  func record(authorList: AuthorListCall) {
    recordedAuthorListCalls.append(authorList)
  }

  func record(viewPullRequestURI: String) {
    recordedViewPullRequestURIs.append(viewPullRequestURI)
  }

  func record(authoritativePullRequestURI: String) {
    recordedAuthoritativePullRequestURIs.append(authoritativePullRequestURI)
  }

  func record(patchURI: String, roundNumber: Int?) {
    recordedPatchCalls.append(.init(uri: patchURI, roundNumber: roundNumber))
  }

  func record(create: CreateCall) {
    recordedCreateCalls.append(create)
  }

  func record(createStack: CreateStackCall) {
    recordedCreateStackCalls.append(createStack)
  }

  func record(statusURI: String, status: PullRequestStatus) {
    recordedStatusCalls.append(.init(uri: statusURI, status: status))
  }

  func record(edit: EditCall) {
    recordedEditCalls.append(edit)
  }

  func record(resubmit: ResubmitCall) {
    recordedResubmitCalls.append(resubmit)
  }

  func recordForkResubmit() {
    recordedForkResubmitCount += 1
  }

  func recordCommentWrite() {
    recordedCommentWriteCount += 1
  }

  func references() -> [String] {
    recordedReferences
  }

  func owners() -> [String] {
    recordedOwners
  }

  func listCalls() -> [ListCall] {
    recordedListCalls
  }

  func authorListCalls() -> [AuthorListCall] {
    recordedAuthorListCalls
  }

  func pullRequestURIs() -> [String] {
    recordedViewPullRequestURIs + recordedAuthoritativePullRequestURIs
  }

  func viewPullRequestURIs() -> [String] {
    recordedViewPullRequestURIs
  }

  func authoritativePullRequestURIs() -> [String] {
    recordedAuthoritativePullRequestURIs
  }

  func patchCalls() -> [PatchCall] {
    recordedPatchCalls
  }

  func createCalls() -> [CreateCall] {
    recordedCreateCalls
  }

  func createStackCalls() -> [CreateStackCall] {
    recordedCreateStackCalls
  }

  func statusCalls() -> [StatusCall] {
    recordedStatusCalls
  }

  func editCalls() -> [EditCall] {
    recordedEditCalls
  }

  func resubmitCalls() -> [ResubmitCall] {
    recordedResubmitCalls
  }

  func forkResubmitCount() -> Int {
    recordedForkResubmitCount
  }

  func commentWriteCount() -> Int {
    recordedCommentWriteCount
  }
}
