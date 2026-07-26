import Foundation
import SwiftTangled

struct IssueCommandDependencies: Sendable {
  let resolveRepository: @Sendable (String) async throws -> TangledRecord<Repository>
  let resolveOwnerDID: @Sendable (String) async throws -> String
  let issues:
    @Sendable (String, String?, IssueStatus?, String?, Int, BobbinSortOrder) async throws -> Page<
      IssueListItem
    >
  let viewIssue: @Sendable (String) async throws -> TangledRecord<Issue>
  let authoritativeIssue: @Sendable (String) async throws -> TangledRecord<Issue>
  let comments: @Sendable (String, String?, Int) async throws -> Page<TangledRecord<Comment>>
  let createIssue: @Sendable (String, String, String?) async throws -> TangledRecord<Issue>
  let createComment: @Sendable (RecordReference, String) async throws -> TangledRecord<Comment>
  let updateIssue: @Sendable (TangledRecord<Issue>, String, String?) async throws -> TangledRecord<Issue>
  let setIssueState: @Sendable (String, IssueStatus) async throws -> TangledRecord<IssueState>
  let originURL: @Sendable () throws -> String

  static let live: IssueCommandDependencies = {
    let client = BobbinClient()
    let locator = RepositoryLocator(client: client)
    return IssueCommandDependencies(
      resolveRepository: { try await locator.resolve($0) },
      resolveOwnerDID: { try await locator.resolveOwnerDID($0) },
      issues: { repositoryDID, authorDID, state, cursor, limit, order in
        try await client.issues(
          repositoryDID: repositoryDID,
          authorDID: authorDID,
          state: state,
          cursor: cursor,
          limit: limit,
          order: order
        )
      },
      viewIssue: { try await client.issue(uri: $0) },
      authoritativeIssue: { try await client.issue(uri: $0) },
      comments: { uri, cursor, limit in
        try await client.comments(subjectURI: uri, cursor: cursor, limit: limit)
      },
      createIssue: { repositoryDID, title, body in
        try await PDSClient.restore(from: CLISessionStore.make().store).createIssue(
          repositoryDID: repositoryDID,
          title: title,
          body: body
        )
      },
      createComment: { subject, body in
        try await PDSClient.restore(from: CLISessionStore.make().store).createComment(
          subject: subject,
          body: body
        )
      },
      updateIssue: { current, title, body in
        try await PDSClient.restore(from: CLISessionStore.make().store).updateIssue(
          current: current,
          title: title,
          body: body
        )
      },
      setIssueState: { issueURI, state in
        try await PDSClient.restore(from: CLISessionStore.make().store).setIssueState(
          issueURI: issueURI,
          state: state
        )
      },
      originURL: { try GitOriginReader().read() }
    )
  }()
}

struct IssueCommandService: Sendable {
  private let dependencies: IssueCommandDependencies
  private let formatter: CLIFormatter

  init(
    dependencies: IssueCommandDependencies = .live,
    formatter: CLIFormatter = .plain
  ) {
    self.dependencies = dependencies
    self.formatter = formatter
  }

  func list(
    repository: String?,
    author: String?,
    state: IssueStatus?,
    limit: Int,
    cursor: String?,
    sort: BobbinSortOrder = .descending,
    json: Bool
  ) async throws -> CLICommandOutput {
    let reference = try repository ?? dependencies.originURL()
    let repositoryRecord = try await dependencies.resolveRepository(reference)
    guard let repositoryDID = repositoryRecord.value.repoDID, !repositoryDID.isEmpty else {
      throw TangledError.invalidRequest(
        "repository does not expose a repository DID: \(repositoryRecord.uri)"
      )
    }
    let authorDID: String?
    if let author {
      authorDID = try await dependencies.resolveOwnerDID(author)
    } else {
      authorDID = nil
    }
    let page = try await dependencies.issues(
      repositoryDID,
      authorDID,
      state,
      cursor,
      limit,
      sort
    )
    return CLICommandOutput(
      stdout: try json ? formatter.json(page) : format(page.items),
      stderr: formatter.cursorDiagnostic(page.cursor, json: json)
    )
  }

  func view(
    issueURI: String,
    comments: Bool = false,
    commentLimit: Int = 30,
    commentCursor: String? = nil,
    json: Bool
  ) async throws -> CLICommandOutput {
    let record = try await dependencies.viewIssue(issueURI)
    guard comments else {
      return CLICommandOutput(stdout: try json ? formatter.json(record) : format(record))
    }
    let page = try await dependencies.comments(issueURI, commentCursor, commentLimit)
    let result = IssueViewWithCommentsResult(issue: record, comments: page)
    return CLICommandOutput(
      stdout: try json ? formatter.json(result) : format(record) + format(page.items),
      stderr: formatter.cursorDiagnostic(page.cursor, json: json)
    )
  }

  func create(
    repository: String?,
    title: String,
    body: String?,
    bodyFile: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let reference = try repository ?? dependencies.originURL()
    let repositoryRecord = try await dependencies.resolveRepository(reference)
    guard let repositoryDID = repositoryRecord.value.repoDID, !repositoryDID.isEmpty else {
      throw TangledError.invalidRequest(
        "repository does not expose a repository DID: \(repositoryRecord.uri)"
      )
    }
    let resolvedBody =
      if let bodyFile {
        try String(contentsOfFile: bodyFile, encoding: .utf8)
      } else {
        body
      }
    let record = try await dependencies.createIssue(repositoryDID, title, resolvedBody)
    return CLICommandOutput(stdout: try json ? formatter.json(record) : format(record))
  }

  func comment(
    issueURI: String,
    body: String?,
    bodyFile: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let issue = try await dependencies.authoritativeIssue(issueURI)
    guard let cid = issue.cid, !cid.isEmpty else {
      throw TangledError.invalidRequest("issue does not expose a CID")
    }
    let resolvedBody =
      if let bodyFile {
        try String(contentsOfFile: bodyFile, encoding: .utf8)
      } else {
        body ?? ""
      }
    let record = try await dependencies.createComment(
      RecordReference(uri: issue.uri, cid: cid),
      resolvedBody
    )
    return CLICommandOutput(stdout: try json ? formatter.json(record) : format(record))
  }

  func edit(
    issueURI: String,
    title: String?,
    body: String?,
    bodyFile: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let current = try await dependencies.authoritativeIssue(issueURI)
    let resolvedBody: String?
    if let bodyFile {
      resolvedBody = try String(contentsOfFile: bodyFile, encoding: .utf8)
    } else if let body {
      resolvedBody = body
    } else {
      resolvedBody = current.value.body
    }
    let record = try await dependencies.updateIssue(
      current,
      title ?? current.value.title,
      resolvedBody
    )
    return CLICommandOutput(stdout: try json ? formatter.json(record) : format(record))
  }

  func setState(
    issueURI: String,
    state: IssueStatus,
    json: Bool
  ) async throws -> CLICommandOutput {
    let issue = try await dependencies.authoritativeIssue(issueURI)
    let record = try await dependencies.setIssueState(issue.uri, state)
    return CLICommandOutput(stdout: try json ? formatter.json(record) : format(record))
  }
}

extension IssueCommandService {
  fileprivate func format(_ issues: [IssueListItem]) -> String {
    let rows = issues.map { item in
      [
        item.record.uri,
        item.state.rawValue,
        item.record.value.title,
        String(item.commentCount),
        item.record.value.createdAt.rawValue,
      ]
    }
    return formatter.table(
      headers: ["URI", "STATE", "TITLE", "COMMENTS", "CREATED"],
      rows: rows
    )
  }

  fileprivate func format(_ record: TangledRecord<Issue>) -> String {
    let issue = record.value
    return formatter.details([
      ("URI", record.uri),
      ("CID", record.cid),
      ("Repository DID", issue.repositoryDID),
      ("Title", issue.title),
      ("Body", issue.body),
      ("Mentions", issue.mentions.joined(separator: ", ")),
      ("References", issue.references.joined(separator: ", ")),
      ("Created", issue.createdAt.rawValue),
    ])
  }

  fileprivate func format(_ comments: [TangledRecord<Comment>]) -> String {
    guard !comments.isEmpty else {
      return "\nComments\nNo comments.\n"
    }
    let rows = comments.map { record in
      [
        record.uri,
        record.value.body.text,
        record.value.createdAt.rawValue,
      ]
    }
    return "\nComments\n"
      + formatter.table(headers: ["URI", "BODY", "CREATED"], rows: rows)
  }

  fileprivate func format(_ record: TangledRecord<Comment>) -> String {
    formatter.details([
      ("URI", record.uri),
      ("CID", record.cid),
      ("Subject", record.value.context.subject.uri),
      ("Body", record.value.body.text),
      ("Created", record.value.createdAt.rawValue),
    ])
  }

  fileprivate func format(_ record: TangledRecord<IssueState>) -> String {
    formatter.details([
      ("URI", record.uri),
      ("CID", record.cid),
      ("Issue", record.value.issueURI),
      ("State", record.value.state.rawValue),
      ("Created", record.value.createdAt.rawValue),
    ])
  }
}

struct IssueViewWithCommentsResult: Codable, Equatable, Sendable {
  let issue: TangledRecord<Issue>
  let comments: Page<TangledRecord<Comment>>
}
