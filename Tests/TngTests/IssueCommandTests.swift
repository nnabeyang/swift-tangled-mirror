import Foundation
import SwiftAtproto
import SwiftTangled
import Testing
import struct SwiftTangled.Comment
import struct SwiftTangled.Issue

@testable import tng

@Suite struct IssueCommandTests {
  @Test func parsesAllIssueCommandArguments() throws {
    let list = try IssueListCommand.parse([
      "alice.example/core", "--author", "bob.example", "--state", "closed",
      "--limit", "25", "--cursor", "next", "--sort", "asc", "--json",
    ])
    #expect(list.repository == "alice.example/core")
    #expect(list.author == "bob.example")
    #expect(list.state == "closed")
    #expect(list.limit == 25)
    #expect(list.cursor == "next")
    #expect(list.sort == "asc")
    #expect(list.json)

    let view = try IssueViewCommand.parse([
      sampleIssueURI, "--comments", "--comment-limit", "10",
      "--comment-cursor", "comments-next", "--json",
    ])
    #expect(view.issueURI == sampleIssueURI)
    #expect(view.comments)
    #expect(view.commentLimit == 10)
    #expect(view.commentCursor == "comments-next")
    #expect(view.json)

    let create = try IssueCreateCommand.parse([
      "--repo", "alice.example/core", "--title", "Add command",
      "--body", "Issue body", "--json",
    ])
    #expect(create.repo == "alice.example/core")
    #expect(create.title == "Add command")
    #expect(create.body == "Issue body")
    #expect(create.json)

    let comment = try IssueCommentCommand.parse([
      sampleIssueURI, "--body-file", "comment.md", "--json",
    ])
    #expect(comment.issueURI == sampleIssueURI)
    #expect(comment.bodyFile == "comment.md")
    #expect(comment.json)

    let edit = try IssueEditCommand.parse([
      sampleIssueURI, "--title", "New title", "--body", "", "--json",
    ])
    #expect(edit.issueURI == sampleIssueURI)
    #expect(edit.title == "New title")
    #expect(edit.body == "")
    #expect(edit.json)

    let close = try IssueCloseCommand.parse([sampleIssueURI, "--json"])
    let reopen = try IssueReopenCommand.parse([sampleIssueURI, "--json"])
    #expect(close.issueURI == sampleIssueURI)
    #expect(close.json)
    #expect(reopen.issueURI == sampleIssueURI)
    #expect(reopen.json)

    #expect(throws: (any Error).self) {
      _ = try IssueListCommand.parse(["--state", "merged"])
    }
    #expect(throws: (any Error).self) {
      _ = try IssueListCommand.parse(["--limit", "0"])
    }
    #expect(throws: (any Error).self) {
      _ = try IssueListCommand.parse(["--sort", "newest"])
    }
    #expect(throws: (any Error).self) {
      _ = try IssueCreateCommand.parse([
        "--title", "Title", "--body", "body", "--body-file", "issue.md",
      ])
    }
    #expect(throws: (any Error).self) {
      _ = try IssueViewCommand.parse([sampleIssueURI, "--comment-limit", "0"])
    }
    #expect(throws: (any Error).self) {
      _ = try IssueCommentCommand.parse([sampleIssueURI])
    }
    #expect(throws: (any Error).self) {
      _ = try IssueCommentCommand.parse([
        sampleIssueURI, "--body", "body", "--body-file", "comment.md",
      ])
    }
    #expect(throws: (any Error).self) {
      _ = try IssueEditCommand.parse([sampleIssueURI])
    }
    #expect(throws: (any Error).self) {
      _ = try IssueEditCommand.parse([
        sampleIssueURI, "--body", "body", "--body-file", "issue.md",
      ])
    }
  }

  @Test func listResolvesRepositoryAndAuthorAndFormatsPage() async throws {
    let recorder = IssueCommandRecorder()
    let service = IssueCommandService(
      dependencies: dependencies(
        recorder: recorder,
        issueRecord: sampleIssueRecord(title: "Fix\tlogin\nflow")
      )
    )

    let output = try await service.list(
      repository: "alice.example/core",
      author: "bob.example",
      state: .closed,
      limit: 25,
      cursor: "previous",
      sort: .ascending,
      json: false
    )

    #expect(output.stdout.hasPrefix("URI\tSTATE\tTITLE\tCOMMENTS\tCREATED\n"))
    #expect(output.stdout.contains("\tclosed\tFix login flow\t4\t"))
    #expect(output.stderr == "Next cursor: next-page\n")
    #expect(await recorder.references() == ["alice.example/core"])
    #expect(await recorder.owners() == ["bob.example"])
    #expect(
      await recorder.listCalls()
        == [
          .init(
            repositoryDID: "did:plc:repository",
            authorDID: "did:plc:resolved-author",
            state: .closed,
            cursor: "previous",
            limit: 25,
            order: .ascending
          )
        ]
    )
  }

  @Test func listUsesOriginFallbackAndPreservesPageJSON() async throws {
    let recorder = IssueCommandRecorder()
    let service = IssueCommandService(
      dependencies: dependencies(
        recorder: recorder,
        originURL: { "git@tangled.org:alice.example/core.git" }
      )
    )

    let output = try await service.list(
      repository: nil,
      author: nil,
      state: nil,
      limit: 30,
      cursor: nil,
      json: true
    )

    let page = try JSONDecoder().decode(Page<IssueListItem>.self, from: Data(output.stdout.utf8))
    #expect(page.cursor == "next-page")
    #expect(page.items.first?.record.uri == sampleIssueURI)
    #expect(output.stderr.isEmpty)
    #expect(await recorder.references() == ["git@tangled.org:alice.example/core.git"])
  }

  @Test func viewFormatsHumanOutputAndPreservesRecordJSON() async throws {
    let recorder = IssueCommandRecorder()
    let service = IssueCommandService(dependencies: dependencies(recorder: recorder))

    let human = try await service.view(issueURI: sampleIssueURI, json: false)
    let json = try await service.view(issueURI: sampleIssueURI, json: true)

    #expect(human.stdout.contains("Title\tLogin fails"))
    #expect(human.stdout.contains("Body\tSteps to reproduce"))
    #expect(human.stdout.contains("Repository DID\tdid:plc:repository"))
    #expect(human.isPageable)
    #expect(!json.isPageable)
    let record = try JSONDecoder().decode(
      TangledRecord<Issue>.self,
      from: Data(json.stdout.utf8)
    )
    #expect(record.uri == sampleIssueURI)
    #expect(record.value.title == "Login fails")
    #expect(await recorder.viewIssueURIs() == [sampleIssueURI, sampleIssueURI])
    #expect(await recorder.authoritativeIssueURIs().isEmpty)
  }

  @Test func viewCanIncludeCommentsAndCursor() async throws {
    let recorder = IssueCommandRecorder()
    let service = IssueCommandService(dependencies: dependencies(recorder: recorder))

    let human = try await service.view(
      issueURI: sampleIssueURI,
      comments: true,
      commentLimit: 10,
      commentCursor: "previous",
      json: false
    )
    #expect(human.stdout.contains("\nComments\nURI\tBODY\tCREATED\n"))
    #expect(human.stdout.contains("Please add a test."))
    #expect(human.stderr == "Next cursor: comments-next\n")
    #expect(human.isPageable)

    let json = try await service.view(
      issueURI: sampleIssueURI,
      comments: true,
      commentLimit: 10,
      commentCursor: nil,
      json: true
    )
    let result = try JSONDecoder().decode(
      IssueViewWithCommentsResult.self,
      from: Data(json.stdout.utf8)
    )
    #expect(result.issue.uri == sampleIssueURI)
    #expect(result.comments.items.first?.value.body.markdown?.text == "Please add a test.")
    #expect(result.comments.cursor == "comments-next")
    #expect(json.stderr.isEmpty)
    #expect(!json.isPageable)
    #expect(
      await recorder.commentListCalls()
        == [
          .init(subjectURI: sampleIssueURI, cursor: "previous", limit: 10),
          .init(subjectURI: sampleIssueURI, cursor: nil, limit: 10),
        ]
    )
  }

  @Test func listRejectsRepositoryWithoutRepositoryDID() async {
    let recorder = IssueCommandRecorder()
    let repository = sampleRepositoryRecord(repositoryDID: nil)
    let service = IssueCommandService(
      dependencies: dependencies(recorder: recorder, repositoryRecord: repository)
    )

    await #expect(throws: TangledError.self) {
      _ = try await service.list(
        repository: "alice.example/core",
        author: nil,
        state: nil,
        limit: 30,
        cursor: nil,
        json: false
      )
    }
    #expect(await recorder.listCalls().isEmpty)
  }

  @Test func createUsesOriginReadsBodyFileAndFormatsResult() async throws {
    let recorder = IssueCommandRecorder()
    let bodyFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("tng-issue-body-\(UUID().uuidString).md")
    try Data("Body from file\n".utf8).write(to: bodyFile)
    defer { try? FileManager.default.removeItem(at: bodyFile) }
    let service = IssueCommandService(
      dependencies: dependencies(
        recorder: recorder,
        originURL: { "git@tangled.org:alice.example/core.git" }
      )
    )

    let output = try await service.create(
      repository: nil,
      title: "Created issue",
      body: nil,
      bodyFile: bodyFile.path,
      json: false
    )

    #expect(output.stdout.contains("Title\tCreated issue"))
    #expect(output.stdout.contains("Body\tBody from file"))
    #expect(await recorder.references() == ["git@tangled.org:alice.example/core.git"])
    #expect(
      await recorder.createCalls()
        == [
          .init(
            repositoryDID: "did:plc:repository",
            title: "Created issue",
            body: "Body from file\n"
          )
        ]
    )
  }

  @Test func createPreservesRecordJSONAndRejectsMissingRepositoryDID() async throws {
    let recorder = IssueCommandRecorder()
    let service = IssueCommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.create(
      repository: "alice.example/core",
      title: "Created issue",
      body: "Body",
      bodyFile: nil,
      json: true
    )
    let record = try JSONDecoder().decode(
      TangledRecord<Issue>.self,
      from: Data(output.stdout.utf8)
    )
    #expect(record.value.title == "Created issue")

    let invalid = IssueCommandService(
      dependencies: dependencies(
        recorder: recorder,
        repositoryRecord: sampleRepositoryRecord(repositoryDID: nil)
      )
    )
    await #expect(throws: TangledError.self) {
      _ = try await invalid.create(
        repository: "alice.example/core",
        title: "Title",
        body: nil,
        bodyFile: nil,
        json: false
      )
    }
  }

  @Test func commentReadsBodyFileAndUsesIssueStrongReference() async throws {
    let recorder = IssueCommandRecorder()
    let bodyFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("tng-issue-comment-\(UUID().uuidString).md")
    try Data("Comment from file\n".utf8).write(to: bodyFile)
    defer { try? FileManager.default.removeItem(at: bodyFile) }
    let service = IssueCommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.comment(
      issueURI: sampleIssueURI,
      body: nil,
      bodyFile: bodyFile.path,
      json: false
    )

    #expect(output.stdout.contains("Body\tComment from file"))
    #expect(
      await recorder.createCommentCalls()
        == [
          .init(
            subject: RecordReference(uri: sampleIssueURI, cid: "bafyissue"),
            body: "Comment from file\n"
          )
        ]
    )
    #expect(await recorder.viewIssueURIs().isEmpty)
    #expect(await recorder.authoritativeIssueURIs() == [sampleIssueURI])
  }

  @Test func commentPreservesJSONAndRejectsIssueWithoutCID() async throws {
    let recorder = IssueCommandRecorder()
    let service = IssueCommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.comment(
      issueURI: sampleIssueURI,
      body: "Comment body",
      bodyFile: nil,
      json: true
    )
    let record = try JSONDecoder().decode(
      TangledRecord<Comment>.self,
      from: Data(output.stdout.utf8)
    )
    #expect(record.value.context.subject.uri == sampleIssueURI)
    #expect(record.value.context.pullRequestRoundIndex == nil)

    let invalid = IssueCommandService(
      dependencies: dependencies(
        recorder: recorder,
        issueRecord: sampleIssueRecord(cid: nil)
      )
    )
    await #expect(throws: TangledError.self) {
      _ = try await invalid.comment(
        issueURI: sampleIssueURI,
        body: "Comment body",
        bodyFile: nil,
        json: false
      )
    }
    #expect(await recorder.createCommentCalls().count == 1)
  }

  @Test func editPreservesUnspecifiedFieldsAndReadsBodyFile() async throws {
    let recorder = IssueCommandRecorder()
    let bodyFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("tng-issue-edit-\(UUID().uuidString).md")
    try Data("Updated from file\n".utf8).write(to: bodyFile)
    defer { try? FileManager.default.removeItem(at: bodyFile) }
    let service = IssueCommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.edit(
      issueURI: sampleIssueURI,
      title: nil,
      body: nil,
      bodyFile: bodyFile.path,
      json: false
    )

    #expect(output.stdout.contains("Title\tLogin fails"))
    #expect(output.stdout.contains("Body\tUpdated from file"))
    let call = try #require(await recorder.updateCalls().first)
    #expect(call.current.uri == sampleIssueURI)
    #expect(call.title == "Login fails")
    #expect(call.body == "Updated from file\n")
    #expect(await recorder.viewIssueURIs().isEmpty)
    #expect(await recorder.authoritativeIssueURIs() == [sampleIssueURI])
  }

  @Test func editPreservesJSONAndCanClearBody() async throws {
    let recorder = IssueCommandRecorder()
    let service = IssueCommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.edit(
      issueURI: sampleIssueURI,
      title: "Updated title",
      body: "",
      bodyFile: nil,
      json: true
    )

    let record = try JSONDecoder().decode(
      TangledRecord<Issue>.self,
      from: Data(output.stdout.utf8)
    )
    #expect(record.value.title == "Updated title")
    #expect(record.value.body == "")
    let call = try #require(await recorder.updateCalls().first)
    #expect(call.body == "")
  }

  @Test func editPropagatesConflictWithoutRetrying() async {
    let recorder = IssueCommandRecorder()
    let service = IssueCommandService(
      dependencies: dependencies(
        recorder: recorder,
        updateIssueError: .conflict(nil)
      )
    )

    await #expect(throws: TangledError.self) {
      _ = try await service.edit(
        issueURI: sampleIssueURI,
        title: "Updated title",
        body: nil,
        bodyFile: nil,
        json: false
      )
    }

    #expect(await recorder.authoritativeIssueURIs() == [sampleIssueURI])
    #expect(await recorder.updateCalls().count == 1)
  }

  @Test func closeAndReopenFetchIssueAndCreateStateRecords() async throws {
    let recorder = IssueCommandRecorder()
    let service = IssueCommandService(dependencies: dependencies(recorder: recorder))

    let closed = try await service.setState(
      issueURI: sampleIssueURI,
      state: .closed,
      json: false
    )
    let reopened = try await service.setState(
      issueURI: sampleIssueURI,
      state: .open,
      json: true
    )

    #expect(closed.stdout.contains("State\tclosed"))
    let record = try JSONDecoder().decode(
      TangledRecord<IssueState>.self,
      from: Data(reopened.stdout.utf8)
    )
    #expect(record.value.state == .open)
    #expect(await recorder.viewIssueURIs().isEmpty)
    #expect(
      await recorder.authoritativeIssueURIs().suffix(2)
        == [sampleIssueURI, sampleIssueURI]
    )
    #expect(
      await recorder.stateCalls()
        == [
          .init(issueURI: sampleIssueURI, state: .closed),
          .init(issueURI: sampleIssueURI, state: .open),
        ]
    )
  }

  @Test func authoritativeReadFailurePreventsIssueWrites() async {
    let recorder = IssueCommandRecorder()
    let service = IssueCommandService(
      dependencies: dependencies(
        recorder: recorder,
        authoritativeIssueError: .serviceUnavailable("PDS unavailable")
      )
    )

    await #expect(throws: TangledError.self) {
      _ = try await service.comment(
        issueURI: sampleIssueURI,
        body: "Comment",
        bodyFile: nil,
        json: false
      )
    }
    await #expect(throws: TangledError.self) {
      _ = try await service.edit(
        issueURI: sampleIssueURI,
        title: "Updated",
        body: nil,
        bodyFile: nil,
        json: false
      )
    }
    await #expect(throws: TangledError.self) {
      _ = try await service.setState(
        issueURI: sampleIssueURI,
        state: .closed,
        json: false
      )
    }

    #expect(await recorder.authoritativeIssueURIs().count == 3)
    #expect(await recorder.createCommentCalls().isEmpty)
    #expect(await recorder.updateCalls().isEmpty)
    #expect(await recorder.stateCalls().isEmpty)
  }
}

extension IssueCommandTests {
  fileprivate func dependencies(
    recorder: IssueCommandRecorder,
    repositoryRecord: TangledRecord<Repository>? = nil,
    issueRecord: TangledRecord<Issue>? = nil,
    authoritativeIssueError: TangledError? = nil,
    updateIssueError: TangledError? = nil,
    originURL: @escaping @Sendable () throws -> String = { "unused" }
  ) -> IssueCommandDependencies {
    let repositoryRecord = repositoryRecord ?? sampleRepositoryRecord()
    let issueRecord = issueRecord ?? sampleIssueRecord()
    return IssueCommandDependencies(
      resolveRepository: { reference in
        await recorder.record(reference: reference)
        return repositoryRecord
      },
      resolveOwnerDID: { owner in
        await recorder.record(owner: owner)
        return owner.hasPrefix("did:") ? owner : "did:plc:resolved-author"
      },
      issues: { repositoryDID, authorDID, state, cursor, limit, order in
        await recorder.record(
          list: .init(
            repositoryDID: repositoryDID,
            authorDID: authorDID,
            state: state,
            cursor: cursor,
            limit: limit,
            order: order
          )
        )
        return Page(
          items: [
            IssueListItem(
              record: issueRecord,
              state: state ?? .open,
              commentCount: 4
            )
          ],
          cursor: "next-page"
        )
      },
      viewIssue: { uri in
        await recorder.record(viewIssueURI: uri)
        return issueRecord
      },
      authoritativeIssue: { uri in
        await recorder.record(authoritativeIssueURI: uri)
        if let authoritativeIssueError {
          throw authoritativeIssueError
        }
        return issueRecord
      },
      comments: { subjectURI, cursor, limit in
        await recorder.record(
          commentList: .init(subjectURI: subjectURI, cursor: cursor, limit: limit)
        )
        return Page(items: [sampleCommentRecord()], cursor: "comments-next")
      },
      coverage: {
        BobbinCoverage(ready: true, eventsProcessed: 100, lastCursor: 100)
      },
      createIssue: { repositoryDID, title, body in
        await recorder.record(
          create: .init(repositoryDID: repositoryDID, title: title, body: body)
        )
        return TangledRecord(
          uri: sampleIssueURI,
          cid: "bafyissue",
          value: Issue(
            repositoryDID: repositoryDID,
            title: title,
            body: body,
            createdAt: FormatString<Date>(rawValue: "2026-07-24T06:45:00Z")
          )
        )
      },
      createComment: { subject, body in
        await recorder.record(createComment: .init(subject: subject, body: body))
        return sampleCommentRecord(subject: subject, body: body)
      },
      updateIssue: { current, title, body in
        await recorder.record(update: .init(current: current, title: title, body: body))
        if let updateIssueError {
          throw updateIssueError
        }
        return TangledRecord(
          uri: current.uri,
          cid: "bafyupdated",
          value: Issue(
            repositoryDID: current.value.repositoryDID,
            title: title,
            body: body,
            createdAt: current.value.createdAt,
            mentions: current.value.mentions,
            references: current.value.references
          )
        )
      },
      setIssueState: { issueURI, state in
        await recorder.record(state: .init(issueURI: issueURI, state: state))
        return TangledRecord(
          uri: "at://did:plc:actor/sh.tangled.repo.issue.state/3state",
          cid: "bafystate",
          value: IssueState(
            issueURI: issueURI,
            state: state,
            createdAt: FormatString<Date>(rawValue: "2026-07-24T08:00:00Z")
          )
        )
      },
      originURL: originURL
    )
  }

  fileprivate func sampleRepositoryRecord(
    repositoryDID: String? = "did:plc:repository"
  ) -> TangledRecord<Repository> {
    TangledRecord(
      uri: "at://did:plc:owner/sh.tangled.repo/core",
      value: Repository(
        name: "core",
        knot: "knot1.tangled.sh",
        repoDID: repositoryDID,
        createdAt: FormatString<Date>(rawValue: "2026-07-20T17:44:38Z")
      )
    )
  }

  fileprivate func sampleIssueRecord(
    title: String = "Login fails",
    cid: String? = "bafyissue"
  ) -> TangledRecord<Issue> {
    TangledRecord(
      uri: sampleIssueURI,
      cid: cid,
      value: Issue(
        repositoryDID: "did:plc:repository",
        title: title,
        body: "Steps to reproduce",
        createdAt: FormatString<Date>(rawValue: "2026-07-20T18:00:00Z"),
        mentions: ["did:plc:mentioned"],
        references: ["at://did:plc:author/sh.tangled.repo.issue/related"]
      )
    )
  }

  fileprivate func sampleCommentRecord(
    subject: RecordReference = .init(uri: sampleIssueURI, cid: "bafyissue"),
    body: String = "Please add a test."
  ) -> TangledRecord<Comment> {
    TangledRecord(
      uri: "at://did:plc:commenter/sh.tangled.feed.comment/3comment",
      cid: "bafycomment",
      value: Comment(
        context: CommentContext(subject: subject),
        body: MarkdownContent(text: body, original: body),
        createdAt: FormatString<Date>(rawValue: "2026-07-24T07:30:00Z")
      )
    )
  }
}

private let sampleIssueURI =
  "at://did:plc:author/sh.tangled.repo.issue/3mr3jt3kbzm22"

private actor IssueCommandRecorder {
  struct ListCall: Equatable, Sendable {
    let repositoryDID: String
    let authorDID: String?
    let state: IssueStatus?
    let cursor: String?
    let limit: Int
    let order: BobbinSortOrder
  }

  struct CreateCall: Equatable, Sendable {
    let repositoryDID: String
    let title: String
    let body: String?
  }

  struct CommentListCall: Equatable, Sendable {
    let subjectURI: String
    let cursor: String?
    let limit: Int
  }

  struct CreateCommentCall: Equatable, Sendable {
    let subject: RecordReference
    let body: String
  }

  struct UpdateCall: Equatable, Sendable {
    let current: TangledRecord<Issue>
    let title: String
    let body: String?
  }

  struct StateCall: Equatable, Sendable {
    let issueURI: String
    let state: IssueStatus
  }

  private var recordedReferences: [String] = []
  private var recordedOwners: [String] = []
  private var recordedListCalls: [ListCall] = []
  private var recordedViewIssueURIs: [String] = []
  private var recordedAuthoritativeIssueURIs: [String] = []
  private var recordedCreateCalls: [CreateCall] = []
  private var recordedCommentListCalls: [CommentListCall] = []
  private var recordedCreateCommentCalls: [CreateCommentCall] = []
  private var recordedUpdateCalls: [UpdateCall] = []
  private var recordedStateCalls: [StateCall] = []

  func record(reference: String) {
    recordedReferences.append(reference)
  }

  func record(owner: String) {
    recordedOwners.append(owner)
  }

  func record(list: ListCall) {
    recordedListCalls.append(list)
  }

  func record(viewIssueURI: String) {
    recordedViewIssueURIs.append(viewIssueURI)
  }

  func record(authoritativeIssueURI: String) {
    recordedAuthoritativeIssueURIs.append(authoritativeIssueURI)
  }

  func record(create: CreateCall) {
    recordedCreateCalls.append(create)
  }

  func record(commentList: CommentListCall) {
    recordedCommentListCalls.append(commentList)
  }

  func record(createComment: CreateCommentCall) {
    recordedCreateCommentCalls.append(createComment)
  }

  func record(update: UpdateCall) {
    recordedUpdateCalls.append(update)
  }

  func record(state: StateCall) {
    recordedStateCalls.append(state)
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

  func viewIssueURIs() -> [String] {
    recordedViewIssueURIs
  }

  func authoritativeIssueURIs() -> [String] {
    recordedAuthoritativeIssueURIs
  }

  func createCalls() -> [CreateCall] {
    recordedCreateCalls
  }

  func commentListCalls() -> [CommentListCall] {
    recordedCommentListCalls
  }

  func createCommentCalls() -> [CreateCommentCall] {
    recordedCreateCommentCalls
  }

  func updateCalls() -> [UpdateCall] {
    recordedUpdateCalls
  }

  func stateCalls() -> [StateCall] {
    recordedStateCalls
  }
}
