import Foundation
import SwiftTangled

struct PRCommandDependencies: Sendable {
  let resolveRepository: @Sendable (String) async throws -> TangledRecord<Repository>
  let resolveOwnerDID: @Sendable (String) async throws -> String
  let pullRequests:
    @Sendable (String, String?, PullRequestStatus?, String?, Int, BobbinSortOrder) async throws ->
      Page<PullRequestListItem>
  let pullRequest: @Sendable (String) async throws -> TangledRecord<PullRequest>
  let comments: @Sendable (String, String?, Int) async throws -> Page<TangledRecord<Comment>>
  let pullRequestPatch: @Sendable (String, Int?) async throws -> PullRequestPatch
  let originURL: @Sendable () throws -> String
  let defaultBranch: @Sendable (String) async throws -> GitDefaultBranch
  let prepare: @Sendable (String, String?, String) throws -> PreparedPullRequest
  let create:
    @Sendable (String, String?, String, String, String, String?, Data) async throws ->
      TangledRecord<PullRequest>
  let createComment: @Sendable (RecordReference, String, Int) async throws -> TangledRecord<Comment>
  let mergeCheck: @Sendable (String) async throws -> PullRequestMergeCheck
  let merge: @Sendable (String, Bool) async throws -> PullRequestMergeResult

  static let live: PRCommandDependencies = {
    let client = BobbinClient()
    let locator = RepositoryLocator(client: client)
    return PRCommandDependencies(
      resolveRepository: { try await locator.resolve($0) },
      resolveOwnerDID: { try await locator.resolveOwnerDID($0) },
      pullRequests: { repositoryDID, authorDID, status, cursor, limit, order in
        try await client.pullRequests(
          repositoryDID: repositoryDID,
          authorDID: authorDID,
          status: status,
          cursor: cursor,
          limit: limit,
          order: order
        )
      },
      pullRequest: { try await client.pullRequest(uri: $0) },
      comments: { uri, cursor, limit in
        try await client.comments(subjectURI: uri, cursor: cursor, limit: limit)
      },
      pullRequestPatch: { uri, roundNumber in
        try await PullRequestPatchLoader(bobbinClient: client).load(
          pullRequestURI: uri,
          roundNumber: roundNumber
        )
      },
      originURL: { try GitOriginReader().read() },
      defaultBranch: { try await client.defaultBranch(repositoryURI: $0) },
      prepare: {
        try GitPullRequestPreparer().prepare(base: $0, head: $1, baseRemote: $2)
      },
      create: { repositoryDID, sourceRepositoryDID, base, head, title, body, patch in
        try await PDSClient.restore(from: CLISessionStore.make().store).createPullRequest(
          repositoryDID: repositoryDID,
          sourceRepositoryDID: sourceRepositoryDID,
          baseBranch: base,
          headBranch: head,
          title: title,
          body: body,
          patch: patch
        )
      },
      createComment: { subject, body, roundIndex in
        try await PDSClient.restore(from: CLISessionStore.make().store).createComment(
          subject: subject,
          body: body,
          pullRequestRoundIndex: roundIndex
        )
      },
      mergeCheck: {
        try await PullRequestMergeService(bobbinClient: client).check(pullRequestURI: $0)
      },
      merge: { uri, allowStack in
        try await PullRequestMergeService(bobbinClient: client).merge(
          pullRequestURI: uri,
          allowStack: allowStack,
          pdsClient: try PDSClient.restore(from: CLISessionStore.make().store)
        )
      }
    )
  }()
}

struct PRCommandService: Sendable {
  private let dependencies: PRCommandDependencies
  private let formatter: CLIFormatter

  init(
    dependencies: PRCommandDependencies = .live,
    formatter: CLIFormatter = .plain
  ) {
    self.dependencies = dependencies
    self.formatter = formatter
  }

  func list(
    repository: String?,
    author: String?,
    status: PullRequestStatus?,
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
    let page = try await dependencies.pullRequests(
      repositoryDID,
      authorDID,
      status,
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
    pullRequestURI: String,
    comments: Bool = false,
    commentLimit: Int = 30,
    commentCursor: String? = nil,
    json: Bool
  ) async throws -> CLICommandOutput {
    let record = try await dependencies.pullRequest(pullRequestURI)
    guard comments else {
      return CLICommandOutput(stdout: try json ? formatter.json(record) : format(record))
    }
    let page = try await dependencies.comments(pullRequestURI, commentCursor, commentLimit)
    let result = PRViewWithCommentsResult(pullRequest: record, comments: page)
    return CLICommandOutput(
      stdout: try json ? formatter.json(result) : format(record) + format(page.items),
      stderr: formatter.cursorDiagnostic(page.cursor, json: json)
    )
  }

  func comment(
    pullRequestURI: String,
    body: String?,
    bodyFile: String?,
    roundNumber: Int?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let pullRequest = try await dependencies.pullRequest(pullRequestURI)
    guard let cid = pullRequest.cid, !cid.isEmpty else {
      throw TangledError.invalidRequest("pull request does not expose a CID")
    }
    guard !pullRequest.value.rounds.isEmpty else {
      throw TangledError.invalidRequest("pull request does not contain a round")
    }
    let roundIndex =
      roundNumber ?? pullRequest.value.rounds.index(before: pullRequest.value.rounds.endIndex)
    guard pullRequest.value.rounds.indices.contains(roundIndex) else {
      throw TangledError.invalidRequest(
        "pull request round index \(roundIndex) is out of range"
      )
    }
    let resolvedBody =
      if let bodyFile {
        try String(contentsOfFile: bodyFile, encoding: .utf8)
      } else {
        body ?? ""
      }
    let record = try await dependencies.createComment(
      RecordReference(uri: pullRequest.uri, cid: cid),
      resolvedBody,
      roundIndex
    )
    return CLICommandOutput(
      stdout: try json ? formatter.json(record) : format(record)
    )
  }

  func diff(pullRequestURI: String, roundNumber: Int?) async throws -> CLICommandOutput {
    let patch = try await dependencies.pullRequestPatch(pullRequestURI, roundNumber)
    return CLICommandOutput(stdoutData: patch.unifiedDiff)
  }

  func merge(
    pullRequestURI: String,
    checkOnly: Bool,
    allowStack: Bool,
    json: Bool
  ) async throws -> CLICommandOutput {
    if checkOnly {
      let result = try await dependencies.mergeCheck(pullRequestURI)
      return CLICommandOutput(stdout: try json ? formatter.json(result) : format(result))
    }
    let result = try await dependencies.merge(pullRequestURI, allowStack)
    return CLICommandOutput(stdout: try json ? formatter.json(result) : format(result))
  }

  func create(
    repository: String?,
    base: String?,
    head: String?,
    title: String?,
    body: String?,
    bodyFile: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let origin = try dependencies.originURL()
    let originRecord = try await dependencies.resolveRepository(origin)
    let targetRecord =
      if let repository {
        try await dependencies.resolveRepository(repository)
      } else {
        originRecord
      }
    guard let originDID = originRecord.value.repoDID,
      let targetDID = targetRecord.value.repoDID
    else {
      throw TangledError.invalidRequest("repository does not expose a repository DID")
    }
    let isFork = originDID != targetDID
    let baseRemote: String
    if isFork {
      guard let source = originRecord.value.source, !source.isEmpty else {
        throw TangledError.invalidRequest(
          "Git origin is not declared as a fork of the target repository"
        )
      }
      let upstreamRecord = try await dependencies.resolveRepository(source)
      guard upstreamRecord.value.repoDID == targetDID else {
        throw TangledError.invalidRequest(
          "Git origin fork metadata points to a different upstream repository"
        )
      }
      baseRemote = try repositoryGitURL(record: targetRecord)
    } else {
      baseRemote = "origin"
    }

    let resolvedBase: String
    if let base {
      resolvedBase = base
    } else {
      resolvedBase = try await dependencies.defaultBranch(targetRecord.uri).name
    }
    let prepared = try dependencies.prepare(resolvedBase, head, baseRemote)
    let resolvedBody: String?
    if let bodyFile {
      resolvedBody = try String(contentsOfFile: bodyFile, encoding: .utf8)
    } else {
      resolvedBody = body ?? prepared.body
    }
    let record = try await dependencies.create(
      targetDID,
      isFork ? originDID : nil,
      prepared.base,
      prepared.head,
      title ?? prepared.title,
      resolvedBody,
      prepared.patch
    )
    let result = PRCreateResult(
      pullRequest: record,
      repositoryPullsURL: repositoryPullsURL(record: targetRecord)
    )
    return CLICommandOutput(
      stdout: try json ? formatter.json(result) : format(result)
    )
  }
}

extension PRCommandService {
  fileprivate func format(_ result: PullRequestMergeCheck) -> String {
    var fields: [(label: String, value: String?)] = [
      ("Mergeable", result.canMerge ? "yes" : "no"),
      ("Pull requests", result.pullRequestURIs.joined(separator: ", ")),
      ("Target", "\(result.repositoryDID):\(result.targetBranch)"),
      ("Message", result.message),
      ("Error", result.error),
    ]
    if !result.conflicts.isEmpty {
      fields.append(
        (
          "Conflicts",
          result.conflicts.map { "\($0.filename): \($0.reason)" }.joined(separator: ", ")
        )
      )
    }
    return formatter.details(fields)
  }

  fileprivate func format(_ result: PullRequestMergeResult) -> String {
    formatter.details([
      ("Merged", result.check.pullRequestURIs.joined(separator: ", ")),
      ("Target", "\(result.check.repositoryDID):\(result.check.targetBranch)"),
      ("Status records", String(result.statusRecords.count)),
    ])
  }

  fileprivate func format(_ result: PRCreateResult) -> String {
    "Created pull request: \(result.pullRequest.uri)\n"
      + "Pull requests: \(result.repositoryPullsURL)\n"
  }

  fileprivate func repositoryPullsURL(record: TangledRecord<Repository>) -> String {
    let owner =
      record.uri.removingPrefix("at://").split(separator: "/").first.map(String.init)
      ?? record.value.repoDID ?? ""
    let name =
      record.value.name
      ?? record.uri.removingPrefix("at://").split(separator: "/").last.map(String.init)
      ?? record.value.repoDID ?? ""
    return "https://tangled.org/\(owner)/\(name)/pulls"
  }

  func repositoryGitURL(record: TangledRecord<Repository>) throws -> String {
    guard let repositoryDID = record.value.repoDID else {
      throw TangledError.invalidRequest("repository does not expose a repository DID")
    }
    let rawBase =
      record.value.knot.contains("://")
      ? record.value.knot : "https://\(record.value.knot)"
    guard let baseURL = URL(string: rawBase),
      baseURL.scheme?.lowercased() == "https",
      baseURL.host != nil
    else {
      throw TangledError.invalidRequest("repository has an invalid Knot endpoint")
    }
    return
      baseURL
      .appendingPathComponent(repositoryDID, isDirectory: true)
      .absoluteString
  }

  fileprivate func format(_ pullRequests: [PullRequestListItem]) -> String {
    let rows = pullRequests.map { item in
      [
        item.record.uri,
        item.status.rawValue,
        item.record.value.title,
        String(item.record.value.rounds.count),
        String(item.commentCount),
        item.record.value.createdAt.rawValue,
      ]
    }
    return formatter.table(
      headers: ["URI", "STATUS", "TITLE", "ROUNDS", "COMMENTS", "CREATED"],
      rows: rows
    )
  }

  fileprivate func format(_ record: TangledRecord<PullRequest>) -> String {
    let pullRequest = record.value
    let fields: [(label: String, value: String?)] = [
      ("URI", record.uri),
      ("CID", record.cid),
      ("Title", pullRequest.title),
      ("Body", pullRequest.body),
      ("Source repository DID", pullRequest.source?.repositoryDID),
      ("Source branch", pullRequest.source?.branch),
      ("Target repository DID", pullRequest.target.repositoryDID),
      ("Target branch", pullRequest.target.branch),
      ("Dependent on", pullRequest.dependentOn),
      ("Mentions", pullRequest.mentions.joined(separator: ", ")),
      ("References", pullRequest.references.joined(separator: ", ")),
      ("Rounds", String(pullRequest.rounds.count)),
      ("Created", pullRequest.createdAt.rawValue),
    ]
    return formatter.details(fields + roundFields(pullRequest.rounds))
  }

  fileprivate func format(_ comments: [TangledRecord<Comment>]) -> String {
    guard !comments.isEmpty else {
      return "\nComments\nNo comments.\n"
    }
    let rows = comments.map { record in
      [
        record.uri,
        record.value.context.pullRequestRoundIndex.map(String.init) ?? "",
        record.value.body.text,
        record.value.createdAt.rawValue,
      ]
    }
    return "\nComments\n"
      + formatter.table(
        headers: ["URI", "ROUND", "BODY", "CREATED"],
        rows: rows
      )
  }

  fileprivate func format(_ record: TangledRecord<Comment>) -> String {
    formatter.details([
      ("URI", record.uri),
      ("CID", record.cid),
      ("Subject", record.value.context.subject.uri),
      ("Round", record.value.context.pullRequestRoundIndex.map(String.init)),
      ("Body", record.value.body.text),
      ("Created", record.value.createdAt.rawValue),
    ])
  }

  fileprivate func roundFields(
    _ rounds: [PullRequestRound]
  ) -> [(label: String, value: String?)] {
    rounds.enumerated().flatMap { index, round in
      let name = "Round \(index)"
      return [
        ("\(name) created", round.createdAt.rawValue),
        ("\(name) patch CID", round.patchBlob.cid),
        ("\(name) patch MIME type", round.patchBlob.mimeType),
        ("\(name) patch size", String(round.patchBlob.size)),
      ]
    }
  }
}

extension String {
  fileprivate func removingPrefix(_ prefix: String) -> String {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
  }
}

struct PRCreateResult: Codable, Equatable, Sendable {
  let pullRequest: TangledRecord<PullRequest>
  let repositoryPullsURL: String
}

struct PRViewWithCommentsResult: Codable, Equatable, Sendable {
  let pullRequest: TangledRecord<PullRequest>
  let comments: Page<TangledRecord<Comment>>
}
