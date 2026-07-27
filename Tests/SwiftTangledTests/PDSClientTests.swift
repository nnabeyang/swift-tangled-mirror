import Foundation
import OAuth4Swift
import SwiftAtproto
import TangledLexicons
import Testing

@testable import SwiftTangled

@Suite struct PDSClientTests {
  private let sessionDID = "did:plc:session"
  private let repositoryDID = "did:plc:repository"
  private let recordKey = "3jzfcijpj2z2a"
  private let createdAt = FormatString<Date>(rawValue: "2026-07-22T12:34:56.000Z")

  @Test func restoreRequiresStoredSession() {
    do {
      _ = try PDSClient.restore(from: InMemorySessionStore())
      Issue.record("Expected authentication failure")
    } catch TangledError.unauthorized {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func starCreatesARepositoryStarRecord() async throws {
    let mock = try PDSXRPCMock(
      listPages: [.init(records: [])],
      putOutput: putOutput()
    )
    let client = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto", "repo:sh.tangled.feed.star"],
      now: { createdAt.typed! },
      nextRecordKey: { recordKey }
    )

    let result = try await client.star(repositoryDID: repositoryDID)

    #expect(result.uri == "at://\(sessionDID)/sh.tangled.feed.star/\(recordKey)")
    #expect(result.cid == "bafystar")
    #expect(result.value == Star(subject: .repository(did: repositoryDID), createdAt: createdAt))

    let requests = await mock.recordedRequests()
    #expect(requests.map(\.nsID) == ["com.atproto.repo.listRecords", "com.atproto.repo.putRecord"])
    #expect(requests[0].query["repo"] == "did%3Aplc%3Asession")
    #expect(requests[0].query["collection"] == "sh.tangled.feed.star")
    #expect(requests[0].query["limit"] == "100")

    let body = try #require(requests[1].body)
    let input = try JSONDecoder().decode(Com.Atproto.RepoPutRecord_Input.self, from: body)
    #expect(input.repo.rawValue == sessionDID)
    #expect(input.collection.rawValue == "sh.tangled.feed.star")
    #expect(input.rkey.rawValue == recordKey)
    #expect(input.validate == nil)
    guard case .record(let record) = input.record,
      let star = record as? Sh.Tangled.FeedStar,
      case .feedStarRepo(let repository) = star.subject
    else {
      Issue.record("Expected a generated repository star record")
      return
    }
    #expect(star.createdAt == createdAt)
    #expect(repository.did.rawValue == repositoryDID)
  }

  @Test func starReturnsExistingRecordWithoutWriting() async throws {
    let existing = starRecord(rkey: recordKey, repositoryDID: repositoryDID)
    let mock = try PDSXRPCMock(listPages: [.init(records: [existing])])
    let client = makeClient(mock: mock)

    let result = try await client.star(repositoryDID: repositoryDID)

    #expect(result.uri == existing.uri.rawValue)
    #expect(result.value.subject == .repository(did: repositoryDID))
    #expect(await mock.recordedRequests().map(\.nsID) == ["com.atproto.repo.listRecords"])
  }

  @Test func unstarDeletesEveryMatchingRecordAcrossPages() async throws {
    let first = starRecord(rkey: recordKey, repositoryDID: repositoryDID)
    let secondKey = "3jzfcijpj2z2b"
    let second = starRecord(rkey: secondKey, repositoryDID: repositoryDID)
    let unrelated = starRecord(rkey: "3jzfcijpj2z2c", repositoryDID: "did:plc:other")
    let mock = try PDSXRPCMock(
      listPages: [
        .init(cursor: "page-2", records: [first, unrelated]),
        .init(records: [second]),
      ]
    )
    let client = makeClient(mock: mock)

    #expect(try await client.unstar(repositoryDID: repositoryDID))

    let requests = await mock.recordedRequests()
    #expect(
      requests.map(\.nsID)
        == [
          "com.atproto.repo.listRecords",
          "com.atproto.repo.listRecords",
          "com.atproto.repo.deleteRecord",
          "com.atproto.repo.deleteRecord",
        ]
    )
    let deletedKeys = try requests.suffix(2).map { request in
      try JSONDecoder().decode(
        Com.Atproto.RepoDeleteRecord_Input.self,
        from: #require(request.body)
      ).rkey.rawValue
    }
    #expect(deletedKeys == [recordKey, secondKey])
  }

  @Test func unstarIsIdempotentWhenNoRecordExists() async throws {
    let mock = try PDSXRPCMock(listPages: [.init(records: [])])
    let client = makeClient(mock: mock)

    #expect(try await !client.unstar(repositoryDID: repositoryDID))
    #expect(await mock.recordedRequests().map(\.nsID) == ["com.atproto.repo.listRecords"])
  }

  @Test func oldSessionWithoutStarScopeRequiresRelogin() async throws {
    let mock = try PDSXRPCMock(listPages: [.init(records: [])])
    let client = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto"]
    )

    do {
      _ = try await client.star(repositoryDID: repositoryDID)
      Issue.record("Expected insufficient scope")
    } catch let TangledError.insufficientScope(scope) {
      #expect(scope == "repo:sh.tangled.feed.star")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await mock.recordedRequests().isEmpty)
  }

  @Test func createIssueWritesGeneratedIssueRecord() async throws {
    let mock = try PDSXRPCMock(
      listPages: [],
      putOutput: .init(
        cid: FormatString(rawValue: "bafyissue"),
        uri: FormatString(
          rawValue: "at://\(sessionDID)/sh.tangled.repo.issue/\(recordKey)"
        )
      )
    )
    let client = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto", "repo:sh.tangled.repo.issue"],
      now: { createdAt.typed! },
      nextRecordKey: { recordKey }
    )

    let result = try await client.createIssue(
      repositoryDID: repositoryDID,
      title: "  Add issue creation  ",
      body: "  Created from tng.  "
    )

    #expect(result.uri == "at://\(sessionDID)/sh.tangled.repo.issue/\(recordKey)")
    #expect(result.cid == "bafyissue")
    #expect(result.value.title == "Add issue creation")
    #expect(result.value.body == "Created from tng.")
    #expect(result.value.repositoryDID == repositoryDID)

    let request = try #require(await mock.recordedRequests().last)
    let input = try JSONDecoder().decode(
      Com.Atproto.RepoPutRecord_Input.self,
      from: #require(request.body)
    )
    #expect(input.collection.rawValue == "sh.tangled.repo.issue")
    #expect(input.repo.rawValue == sessionDID)
    #expect(input.rkey.rawValue == recordKey)
    #expect(input.validate == nil)
    guard case .record(let record) = input.record,
      let issue = record as? Sh.Tangled.RepoIssue
    else {
      Issue.record("Expected a generated issue record")
      return
    }
    #expect(issue.repo.rawValue == repositoryDID)
    #expect(issue.title == "Add issue creation")
    #expect(issue.body == "Created from tng.")
    #expect(issue.createdAt == createdAt)
  }

  @Test func createIssueValidatesInputAndScopeBeforeWriting() async throws {
    let mock = try PDSXRPCMock(listPages: [])
    let scoped = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto", "repo:sh.tangled.repo.issue"]
    )
    let unscoped = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto"]
    )

    await #expect(throws: TangledError.self) {
      _ = try await scoped.createIssue(repositoryDID: "invalid", title: "Title")
    }
    await #expect(throws: TangledError.self) {
      _ = try await scoped.createIssue(repositoryDID: repositoryDID, title: "  ")
    }
    do {
      _ = try await unscoped.createIssue(repositoryDID: repositoryDID, title: "Title")
      Issue.record("Expected insufficient scope")
    } catch let TangledError.insufficientScope(scope) {
      #expect(scope == "repo:sh.tangled.repo.issue")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await mock.recordedRequests().isEmpty)
  }

  @Test func updateIssuePreservesMetadataAndUsesRecordCIDForSwap() async throws {
    let issueURI = "at://\(sessionDID)/sh.tangled.repo.issue/\(recordKey)"
    let mock = try PDSXRPCMock(
      listPages: [],
      putOutput: .init(
        cid: FormatString(rawValue: "bafyupdated"),
        uri: FormatString(rawValue: issueURI)
      )
    )
    let client = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto", "repo:sh.tangled.repo.issue"]
    )
    let current = TangledRecord(
      uri: issueURI,
      cid: "bafycurrent",
      value: Issue(
        repositoryDID: repositoryDID,
        title: "Old title",
        body: "Old body",
        createdAt: createdAt,
        mentions: ["did:plc:mentioned"],
        references: ["at://did:plc:other/sh.tangled.repo.issue/related"]
      )
    )

    let result = try await client.updateIssue(
      current: current,
      title: " Updated title ",
      body: " Updated body "
    )

    #expect(result.cid == "bafyupdated")
    #expect(result.value.title == "Updated title")
    #expect(result.value.body == "Updated body")
    #expect(result.value.createdAt == createdAt)
    #expect(result.value.mentions == current.value.mentions)
    #expect(result.value.references == current.value.references)
    let request = try #require(await mock.recordedRequests().last)
    let input = try JSONDecoder().decode(
      Com.Atproto.RepoPutRecord_Input.self,
      from: #require(request.body)
    )
    #expect(input.collection.rawValue == "sh.tangled.repo.issue")
    #expect(input.rkey.rawValue == recordKey)
    #expect(input.swapRecord?.rawValue == "bafycurrent")
    guard case .record(let record) = input.record,
      let issue = record as? Sh.Tangled.RepoIssue
    else {
      Issue.record("Expected a generated issue record")
      return
    }
    #expect(issue.createdAt == createdAt)
    #expect(issue.mentions?.map(\.rawValue) == current.value.mentions)
    #expect(issue.references?.map(\.rawValue) == current.value.references)
  }

  @Test func updateIssueRejectsInvalidOwnershipCIDAndScopeBeforeWriting() async throws {
    let mock = try PDSXRPCMock(listPages: [])
    let scoped = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["repo:sh.tangled.repo.issue"]
    )
    let unscoped = PDSClient(client: mock, repoDID: sessionDID, authorizedScopes: ["atproto"])
    let issue = Issue(
      repositoryDID: repositoryDID,
      title: "Title",
      createdAt: createdAt
    )

    await #expect(throws: TangledError.self) {
      _ = try await scoped.updateIssue(
        current: TangledRecord(
          uri: "at://did:plc:other/sh.tangled.repo.issue/\(recordKey)",
          cid: "bafycurrent",
          value: issue
        ),
        title: "Title",
        body: nil
      )
    }
    await #expect(throws: TangledError.self) {
      _ = try await scoped.updateIssue(
        current: TangledRecord(
          uri: "at://\(sessionDID)/sh.tangled.repo.issue/\(recordKey)",
          value: issue
        ),
        title: "Title",
        body: nil
      )
    }
    await #expect(throws: TangledError.self) {
      _ = try await unscoped.updateIssue(
        current: TangledRecord(
          uri: "at://\(sessionDID)/sh.tangled.repo.issue/\(recordKey)",
          cid: "bafycurrent",
          value: issue
        ),
        title: "Title",
        body: nil
      )
    }
    #expect(await mock.recordedRequests().isEmpty)
  }

  @Test func updateIssueReportsInvalidSwapAsConflictWithoutRetrying() async throws {
    for failure in [PDSXRPCMock.Failure.oauthInvalidSwap, .xrpcInvalidSwap] {
      let issueURI = "at://\(sessionDID)/sh.tangled.repo.issue/\(recordKey)"
      let mock = try PDSXRPCMock(listPages: [], failure: failure)
      let client = PDSClient(
        client: mock,
        repoDID: sessionDID,
        authorizedScopes: ["atproto", "repo:sh.tangled.repo.issue"]
      )
      let current = TangledRecord(
        uri: issueURI,
        cid: "bafycurrent",
        value: Issue(
          repositoryDID: repositoryDID,
          title: "Old title",
          createdAt: createdAt
        )
      )

      do {
        _ = try await client.updateIssue(
          current: current,
          title: "Updated title",
          body: nil
        )
        Issue.record("Expected record conflict")
      } catch TangledError.conflict {
        // Expected.
      } catch {
        Issue.record("Unexpected error: \(error)")
      }

      #expect(
        await mock.recordedRequests().map(\.nsID)
          == ["com.atproto.repo.putRecord"]
      )
    }
  }

  @Test func updateIssuePreservesOtherGeneratedXRPCErrors() async throws {
    let issueURI = "at://\(sessionDID)/sh.tangled.repo.issue/\(recordKey)"
    let mock = try PDSXRPCMock(listPages: [], failure: .xrpcOther)
    let client = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto", "repo:sh.tangled.repo.issue"]
    )
    let current = TangledRecord(
      uri: issueURI,
      cid: "bafycurrent",
      value: Issue(
        repositoryDID: repositoryDID,
        title: "Old title",
        createdAt: createdAt
      )
    )

    do {
      _ = try await client.updateIssue(
        current: current,
        title: "Updated title",
        body: nil
      )
      Issue.record("Expected generated XRPC failure")
    } catch Com.Atproto.RepoPutRecord.Error.unexpected(let code, let message) {
      #expect(code == "UpstreamFailure")
      #expect(message == "upstream failed")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(await mock.recordedRequests().count == 1)
  }

  @Test func setIssueStateWritesGeneratedOpenAndClosedRecords() async throws {
    let issueURI = "at://did:plc:author/sh.tangled.repo.issue/\(recordKey)"
    let mock = try PDSXRPCMock(
      listPages: [],
      putOutput: .init(
        cid: FormatString(rawValue: "bafystate"),
        uri: FormatString(
          rawValue: "at://\(sessionDID)/sh.tangled.repo.issue.state/\(recordKey)"
        )
      )
    )
    let client = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto", "repo:sh.tangled.repo.issue.state"],
      now: { createdAt.typed! },
      nextRecordKey: { recordKey }
    )

    let closed = try await client.setIssueState(issueURI: issueURI, state: .closed)
    let open = try await client.setIssueState(issueURI: issueURI, state: .open)

    #expect(closed.value.state == .closed)
    #expect(open.value.state == .open)
    let requests = await mock.recordedRequests()
    #expect(requests.count == 2)
    let states = try requests.map { request -> Sh.Tangled.Repo.IssueState in
      let input = try JSONDecoder().decode(
        Com.Atproto.RepoPutRecord_Input.self,
        from: #require(request.body)
      )
      #expect(input.collection.rawValue == "sh.tangled.repo.issue.state")
      guard case .record(let record) = input.record,
        let state = record as? Sh.Tangled.Repo.IssueState
      else {
        throw TangledError.decoding(
          DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "state"))
        )
      }
      return state
    }
    #expect(
      states.map(\.state.rawValue)
        == [
          "sh.tangled.repo.issue.state.closed",
          "sh.tangled.repo.issue.state.open",
        ]
    )
    #expect(states.allSatisfy { $0.issue.rawValue == issueURI })
  }

  @Test func createPullRequestUploadsGzipAndWritesFirstRound() async throws {
    let mock = try PDSXRPCMock(
      listPages: [],
      putOutput: .init(
        cid: FormatString(rawValue: "bafypull"),
        uri: FormatString(
          rawValue: "at://\(sessionDID)/sh.tangled.repo.pull/\(recordKey)"
        )
      )
    )
    let client = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto", "repo:sh.tangled.repo.pull", "blob:*/*"],
      now: { createdAt.typed! },
      nextRecordKey: { recordKey }
    )

    let result = try await client.createPullRequest(
      repositoryDID: repositoryDID,
      baseBranch: "main",
      headBranch: "feature/pr",
      title: "Add PR creation",
      body: "Create the first round.",
      patch: Data("From abcdef Mon Sep 17 00:00:00 2001\n".utf8)
    )

    #expect(result.uri == "at://\(sessionDID)/sh.tangled.repo.pull/\(recordKey)")
    #expect(result.value.target.branch == "main")
    #expect(result.value.source?.branch == "feature/pr")
    #expect(result.value.rounds.count == 1)

    let requests = await mock.recordedRequests()
    #expect(requests.map(\.nsID) == ["com.atproto.repo.uploadBlob", "com.atproto.repo.putRecord"])
    let gzip = try #require(requests[0].body)
    #expect(Array(gzip.prefix(2)) == [0x1f, 0x8b])
    let input = try JSONDecoder().decode(
      Com.Atproto.RepoPutRecord_Input.self,
      from: #require(requests[1].body)
    )
    #expect(input.collection.rawValue == "sh.tangled.repo.pull")
    #expect(input.validate == nil)
    let recordBody = try #require(requests[1].body)
    let decodedObject = try JSONSerialization.jsonObject(with: recordBody)
    let object = try #require(decodedObject as? [String: Any])
    let pull = try #require(object["record"] as? [String: Any])
    let target = try #require(pull["target"] as? [String: Any])
    let source = try #require(pull["source"] as? [String: Any])
    let rounds = try #require(pull["rounds"] as? [[String: Any]])
    let patchBlob = try #require(rounds.first?["patchBlob"] as? [String: Any])
    #expect(target["repo"] as? String == repositoryDID)
    #expect(target["branch"] as? String == "main")
    #expect(source["branch"] as? String == "feature/pr")
    #expect(source["repo"] == nil)
    #expect(patchBlob["mimeType"] as? String == "application/gzip")
  }

  @Test func setPullRequestStatusWritesOpenClosedAndMergedRecords() async throws {
    let mock = try PDSXRPCMock(listPages: [])
    let client = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto", "repo:sh.tangled.repo.pull.status"],
      now: { createdAt.typed! },
      nextRecordKey: { recordKey }
    )
    let pullRequestURI = "at://did:plc:author/sh.tangled.repo.pull/3pull"

    let closed = try await client.setPullRequestStatus(pullRequestURI, status: .closed)
    let open = try await client.setPullRequestStatus(pullRequestURI, status: .open)
    let merged = try await client.markPullRequestsMerged([pullRequestURI])

    #expect(closed.value.status == .closed)
    #expect(open.value.status == .open)
    #expect(merged.first?.value.status == .merged)
    #expect(closed.value.pullRequestURI == pullRequestURI)
    #expect(closed.value.createdAt == createdAt)

    let requests = await mock.recordedRequests()
    #expect(requests.map(\.nsID) == Array(repeating: "com.atproto.repo.applyWrites", count: 3))
    let expectedStatuses = [
      "sh.tangled.repo.pull.status.closed",
      "sh.tangled.repo.pull.status.open",
      "sh.tangled.repo.pull.status.merged",
    ]
    for (request, expectedStatus) in zip(requests, expectedStatuses) {
      let input = try JSONDecoder().decode(
        Com.Atproto.RepoApplyWrites_Input.self,
        from: #require(request.body)
      )
      #expect(input.repo.rawValue == sessionDID)
      #expect(input.validate == nil)
      guard case .repoApplyWritesCreate(let write) = input.writes.first,
        case .record(let value) = write.value,
        let status = value as? Sh.Tangled.Repo.PullStatus
      else {
        Issue.record("Expected a generated pull status record")
        continue
      }
      #expect(write.collection.rawValue == "sh.tangled.repo.pull.status")
      #expect(status.pull.rawValue == pullRequestURI)
      #expect(status.status.rawValue == expectedStatus)
    }
  }

  @Test func setPullRequestStatusValidatesStatusURIAndScopeBeforeWriting() async throws {
    let mock = try PDSXRPCMock(listPages: [])
    let client = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto", "repo:sh.tangled.repo.pull.status"]
    )

    await #expect(throws: TangledError.self) {
      _ = try await client.setPullRequestStatus(
        "at://did:plc:author/sh.tangled.repo.issue/3issue",
        status: .closed
      )
    }
    await #expect(throws: TangledError.self) {
      _ = try await client.setPullRequestStatus(
        "at://did:plc:author/sh.tangled.repo.pull/3pull",
        status: PullRequestStatus(rawValue: "draft")
      )
    }

    let missingScope = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto"]
    )
    await #expect(throws: TangledError.self) {
      _ = try await missingScope.setPullRequestStatus(
        "at://did:plc:author/sh.tangled.repo.pull/3pull",
        status: .closed
      )
    }
    #expect(await mock.recordedRequests().isEmpty)
  }

  @Test func createForkPullRequestWritesSourceRepositoryAndAllowsMatchingBranchNames() async throws {
    let sourceRepositoryDID = "did:plc:fork"
    let mock = try PDSXRPCMock(
      listPages: [],
      putOutput: .init(
        cid: FormatString(rawValue: "bafyforkpull"),
        uri: FormatString(
          rawValue: "at://\(sessionDID)/sh.tangled.repo.pull/\(recordKey)"
        )
      )
    )
    let client = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto", "repo:sh.tangled.repo.pull", "blob:*/*"],
      now: { createdAt.typed! },
      nextRecordKey: { recordKey }
    )

    let result = try await client.createPullRequest(
      repositoryDID: repositoryDID,
      sourceRepositoryDID: sourceRepositoryDID,
      baseBranch: "main",
      headBranch: "main",
      title: "Fork pull request",
      patch: Data("From fork\n".utf8)
    )

    #expect(result.value.source?.repositoryDID == sourceRepositoryDID)
    let request = try #require(await mock.recordedRequests().last)
    let body = try #require(request.body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let pull = try #require(object["record"] as? [String: Any])
    let source = try #require(pull["source"] as? [String: Any])
    #expect(source["branch"] as? String == "main")
    #expect(source["repo"] as? String == sourceRepositoryDID)
  }

  @Test func createCommentWritesMarkdownForPullRequestRound() async throws {
    let mock = try PDSXRPCMock(
      listPages: [],
      putOutput: .init(
        cid: FormatString(rawValue: "bafycomment"),
        uri: FormatString(
          rawValue: "at://\(sessionDID)/sh.tangled.feed.comment/\(recordKey)"
        )
      )
    )
    let client = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto", "repo:sh.tangled.feed.comment"],
      now: { createdAt.typed! },
      nextRecordKey: { recordKey }
    )
    let subject = RecordReference(
      uri: "at://did:plc:author/sh.tangled.repo.pull/3pull",
      cid: "bafypull"
    )

    let result = try await client.createComment(
      subject: subject,
      body: "Please add a test.",
      pullRequestRoundIndex: 1
    )

    #expect(result.value.context.subject == subject)
    #expect(result.value.context.pullRequestRoundIndex == 1)
    let request = try #require(await mock.recordedRequests().last)
    let requestBody = try #require(request.body)
    let object = try #require(
      JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
    )
    let record = try #require(object["record"] as? [String: Any])
    let body = try #require(record["body"] as? [String: Any])
    let writtenSubject = try #require(record["subject"] as? [String: Any])
    #expect(record["$type"] as? String == "sh.tangled.feed.comment")
    #expect(record["pullRoundIdx"] as? Int == 1)
    #expect(body["text"] as? String == "Please add a test.")
    #expect(writtenSubject["uri"] as? String == subject.uri)
    #expect(writtenSubject["cid"] as? String == subject.cid)
  }

  @Test func createCommentForIssueOmitsPullRequestRound() async throws {
    let mock = try PDSXRPCMock(
      listPages: [],
      putOutput: .init(
        cid: FormatString(rawValue: "bafycomment"),
        uri: FormatString(
          rawValue: "at://\(sessionDID)/sh.tangled.feed.comment/\(recordKey)"
        )
      )
    )
    let client = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto", "repo:sh.tangled.feed.comment"],
      now: { createdAt.typed! },
      nextRecordKey: { recordKey }
    )
    let subject = RecordReference(
      uri: "at://did:plc:author/sh.tangled.repo.issue/3issue",
      cid: "bafyissue"
    )

    let result = try await client.createComment(subject: subject, body: "Issue comment")

    #expect(result.value.context.subject == subject)
    #expect(result.value.context.pullRequestRoundIndex == nil)
    let request = try #require(await mock.recordedRequests().last)
    let requestBody = try #require(request.body)
    let object = try #require(
      JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
    )
    let record = try #require(object["record"] as? [String: Any])
    #expect(record["pullRoundIdx"] == nil)
  }

  @Test func networkFailureIsNotRetried() async throws {
    let mock = try PDSXRPCMock(
      listPages: [.init(records: [])],
      failingNSID: "com.atproto.repo.listRecords"
    )
    let client = makeClient(mock: mock)

    do {
      _ = try await client.star(repositoryDID: repositoryDID)
      Issue.record("Expected network error")
    } catch is TangledError {
      // Expected.
    }
    #expect(await mock.recordedRequests().count == 1)
  }
}

extension PDSClientTests {
  private func makeClient(mock: PDSXRPCMock) -> PDSClient {
    PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto", "repo:sh.tangled.feed.star"]
    )
  }

  private func starRecord(
    rkey: String,
    repositoryDID: String
  ) -> Com.Atproto.RepoListRecords_Record {
    .init(
      cid: FormatString(rawValue: "bafy\(rkey)"),
      uri: FormatString(
        rawValue: "at://\(sessionDID)/sh.tangled.feed.star/\(rkey)"
      ),
      value: .record(
        Sh.Tangled.FeedStar(
          createdAt: createdAt,
          subject: .feedStarRepo(.init(did: FormatString(rawValue: repositoryDID)))
        )
      )
    )
  }

  private func putOutput() -> Com.Atproto.RepoPutRecord_Output {
    .init(
      cid: FormatString(rawValue: "bafystar"),
      uri: FormatString(
        rawValue: "at://\(sessionDID)/sh.tangled.feed.star/\(recordKey)"
      )
    )
  }
}

@Suite
struct PDSArtifactTests {
  private let sessionDID = "did:plc:session"
  private let repositoryDID = "did:plc:repository"
  private let repositoryURI = "at://did:plc:owner/sh.tangled.repo/core"
  private let recordKey = "3martifact"
  private let tagHash = String(repeating: "bb", count: 20)
  private let blobCID = "bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a"

  @Test func uploadCreatesArtifactBlobAndRecord() async throws {
    let uri = "at://\(sessionDID)/sh.tangled.repo.artifact/\(recordKey)"
    let mock = try PDSXRPCMock(
      listPages: [],
      putOutput: .init(
        cid: FormatString(rawValue: "bafyartifactrecord"),
        uri: FormatString(rawValue: uri)
      ),
      uploadOutput: uploadOutput()
    )
    let client = makeClient(mock)

    let result = try await client.uploadArtifact(
      repositoryURI: repositoryURI,
      repositoryDID: repositoryDID,
      tagObjectHash: tagHash,
      name: "artifact-data",
      data: Data("artifact-data".utf8)
    )

    #expect(result.uri == uri)
    #expect(result.value.repositoryDID == repositoryDID)
    #expect(result.value.tagObjectHash == tagHash)
    #expect(result.value.blob.cid == blobCID)
    let requests = await mock.recordedRequests()
    #expect(
      requests.map(\.nsID)
        == ["com.atproto.repo.uploadBlob", "com.atproto.repo.putRecord"]
    )
    let input = try putRecordJSON(from: #require(requests.last?.body))
    #expect(input["repo"] as? String == sessionDID)
    #expect(input["rkey"] as? String == recordKey)
    #expect(input["swapRecord"] == nil)
    let artifact = try #require(input["record"] as? [String: Any])
    #expect(artifact["repo"] as? String == repositoryURI)
    #expect(artifact["repoDid"] as? String == repositoryDID)
    #expect(artifact["name"] as? String == "artifact-data")
    let tag = try #require(artifact["tag"] as? [String: String])
    #expect(tag == ["$bytes": "u7u7u7u7u7u7u7u7u7u7u7u7u7s"])
  }

  @Test(arguments: [
    #""u7u7u7u7u7u7u7u7u7u7u7u7u7s=""#,
    #"{"$bytes":"u7u7u7u7u7u7u7u7u7u7u7u7u7s="}"#,
  ])
  func ownArtifactRecordsAcceptCanonicalAndLegacyTagBytes(_ tagJSON: String) async throws {
    let mock = try PDSXRPCMock(
      listPages: [],
      rawListPages: [
        Data(
          """
          {"records":[{"uri":"at://\(sessionDID)/sh.tangled.repo.artifact/\(recordKey)","cid":"bafyartifactrecord","value":{"$type":"sh.tangled.repo.artifact","artifact":{"$type":"blob","ref":{"$link":"\(blobCID)"},"mimeType":"application/octet-stream","size":13},"createdAt":"2026-07-25T12:34:56Z","name":"artifact-data","repo":"\(repositoryURI)","repoDid":"\(repositoryDID)","tag":\(tagJSON)}}]}
          """.utf8
        )
      ]
    )

    let records = try await makeClient(mock).artifactRecords(
      repositoryDID: repositoryDID
    )

    #expect(records.count == 1)
    #expect(records[0].value.name == "artifact-data")
    #expect(records[0].value.tagObjectHash == tagHash)
    #expect(records[0].value.blob.cid == blobCID)
    #expect(
      await mock.recordedRequests().map(\.nsID)
        == ["com.atproto.repo.listRecords"]
    )
  }

  @Test func forceReplacementUsesExistingRkeyAndCID() async throws {
    let uri = "at://\(sessionDID)/sh.tangled.repo.artifact/\(recordKey)"
    let mock = try PDSXRPCMock(
      listPages: [],
      putOutput: .init(
        cid: FormatString(rawValue: "bafyupdated"),
        uri: FormatString(rawValue: uri)
      ),
      uploadOutput: uploadOutput()
    )
    let client = makeClient(mock)
    let current = artifactRecord(uri: uri, cid: "bafycurrent")

    _ = try await client.uploadArtifact(
      repositoryURI: repositoryURI,
      repositoryDID: repositoryDID,
      tagObjectHash: tagHash,
      name: "artifact-data",
      data: Data("artifact-data".utf8),
      replacing: current
    )

    let request = try #require(await mock.recordedRequests().last)
    let input = try putRecordJSON(from: #require(request.body))
    #expect(input["rkey"] as? String == recordKey)
    #expect(input["swapRecord"] as? String == "bafycurrent")
  }

  @Test func otherAuthorAndMissingScopesFailBeforeUpload() async throws {
    let mock = try PDSXRPCMock(listPages: [], uploadOutput: uploadOutput())
    let client = makeClient(mock)
    let other = artifactRecord(
      uri: "at://did:plc:other/sh.tangled.repo.artifact/\(recordKey)",
      cid: "bafycurrent"
    )

    await #expect(throws: ArtifactError.self) {
      _ = try await client.uploadArtifact(
        repositoryURI: repositoryURI,
        repositoryDID: repositoryDID,
        tagObjectHash: tagHash,
        name: "artifact-data",
        data: Data("artifact-data".utf8),
        replacing: other
      )
    }
    let unscoped = PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: ["atproto"]
    )
    await #expect(throws: TangledError.self) {
      _ = try await unscoped.uploadArtifact(
        repositoryURI: repositoryURI,
        repositoryDID: repositoryDID,
        tagObjectHash: tagHash,
        name: "artifact-data",
        data: Data("artifact-data".utf8)
      )
    }
    #expect(await mock.recordedRequests().isEmpty)
  }

  @Test func deleteUsesRecordCIDAsCompareAndSwap() async throws {
    let uri = "at://\(sessionDID)/sh.tangled.repo.artifact/\(recordKey)"
    let mock = try PDSXRPCMock(listPages: [])
    let client = makeClient(mock)

    try await client.deleteArtifact(artifactRecord(uri: uri, cid: "bafycurrent"))

    let request = try #require(await mock.recordedRequests().last)
    let input = try JSONDecoder().decode(
      Com.Atproto.RepoDeleteRecord_Input.self,
      from: #require(request.body)
    )
    #expect(input.rkey.rawValue == recordKey)
    #expect(input.swapRecord?.rawValue == "bafycurrent")
  }

  private func makeClient(_ mock: PDSXRPCMock) -> PDSClient {
    PDSClient(
      client: mock,
      repoDID: sessionDID,
      authorizedScopes: [
        "atproto",
        "repo:sh.tangled.repo.artifact",
        "blob:*/*",
      ],
      nextRecordKey: { recordKey }
    )
  }

  private func artifactRecord(uri: String, cid: String) -> TangledRecord<Artifact> {
    TangledRecord(
      uri: uri,
      cid: cid,
      value: Artifact(
        repositoryDID: repositoryDID,
        tagObjectHash: tagHash,
        name: "artifact-data",
        blob: BlobReference(
          cid: blobCID,
          mimeType: "application/octet-stream",
          size: 13
        ),
        createdAt: FormatString(rawValue: "2026-07-25T12:34:56Z")
      )
    )
  }

  private func uploadOutput() -> Data {
    Data(
      """
      {"blob":{"$type":"blob","ref":{"$link":"\(blobCID)"},"mimeType":"application/octet-stream","size":13}}
      """.utf8
    )
  }

  private func putRecordJSON(from data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

private actor PDSXRPCMock: XRPCCallable {
  enum Failure: Sendable {
    case oauthInvalidSwap
    case xrpcInvalidSwap
    case xrpcOther
  }

  struct Request: Sendable {
    let nsID: String
    let query: [String: String]
    let body: Data?
  }

  private var listPages: [Data]
  private let putOutput: Data
  private let deleteOutput: Data
  private let uploadOutput: Data
  private let failingNSID: String?
  private let failure: Failure?
  private var requests: [Request] = []

  init(
    listPages: [Com.Atproto.RepoListRecords_Output],
    rawListPages: [Data]? = nil,
    putOutput: Com.Atproto.RepoPutRecord_Output? = nil,
    uploadOutput: Data? = nil,
    failingNSID: String? = nil,
    failure: Failure? = nil
  ) throws {
    let encoder = JSONEncoder()
    self.listPages = try rawListPages ?? listPages.map(encoder.encode)
    self.putOutput = try encoder.encode(
      putOutput
        ?? Com.Atproto.RepoPutRecord_Output(
          cid: FormatString(rawValue: "bafystar"),
          uri: FormatString(rawValue: "at://did:plc:session/sh.tangled.feed.star/3jzfcijpj2z2a")
        )
    )
    self.deleteOutput = try encoder.encode(Com.Atproto.RepoDeleteRecord_Output())
    self.uploadOutput =
      uploadOutput
      ?? Data(
        """
        {"blob":{"$type":"blob","ref":{"$link":"bafkreigh2akiscaildcw453ukxq2grj32w3w6v3ip5ir6v3g7h4xj5d4te"},"mimeType":"application/gzip","size":42}}
        """.utf8
      )
    self.failingNSID = failingNSID
    self.failure = failure
  }

  nonisolated func getProxy(nsid: String) -> String? {
    nil
  }

  func response(_ components: XRPCRequestComponents) async throws -> Data {
    requests.append(
      Request(
        nsID: components.nsId,
        query: Dictionary(
          components.queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
          },
          uniquingKeysWith: { first, _ in first }
        ),
        body: components.body
      )
    )
    if components.nsId == failingNSID {
      throw URLError(.cannotConnectToHost)
    }
    if components.nsId == "com.atproto.repo.putRecord", let failure {
      switch failure {
      case .oauthInvalidSwap:
        let response = try JSONDecoder().decode(
          OAuth.ErrorResponse.self,
          from: Data(#"{"error":"InvalidSwap"}"#.utf8)
        )
        throw OAuth.Errors.oauthError(response, .badRequest)
      case .xrpcInvalidSwap:
        throw Com.Atproto.RepoPutRecord.Error.invalidswap(nil)
      case .xrpcOther:
        throw Com.Atproto.RepoPutRecord.Error.unexpected(
          error: "UpstreamFailure",
          message: "upstream failed"
        )
      }
    }
    switch components.nsId {
    case "com.atproto.repo.uploadBlob":
      return uploadOutput
    case "com.atproto.repo.listRecords":
      return listPages.removeFirst()
    case "com.atproto.repo.putRecord":
      return putOutput
    case "com.atproto.repo.deleteRecord":
      return deleteOutput
    case "com.atproto.repo.applyWrites":
      let input = try JSONDecoder().decode(
        Com.Atproto.RepoApplyWrites_Input.self,
        from: components.body ?? Data()
      )
      let results = input.writes.compactMap { write -> [String: String]? in
        guard case .repoApplyWritesCreate(let create) = write else { return nil }
        return [
          "$type": "com.atproto.repo.applyWrites#createResult",
          "uri":
            "at://did:plc:session/\(create.collection.rawValue)/\(create.rkey?.rawValue ?? "missing")",
          "cid": "bafystatus",
        ]
      }
      return try JSONSerialization.data(withJSONObject: ["results": results])
    default:
      throw URLError(.unsupportedURL)
    }
  }

  func recordedRequests() -> [Request] {
    requests
  }
}
