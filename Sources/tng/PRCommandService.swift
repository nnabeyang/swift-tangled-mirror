import Foundation
import SwiftTangled

struct PRCommandDependencies: Sendable {
  let resolveRepository: @Sendable (String) async throws -> TangledRecord<Repository>
  let resolveOwnerDID: @Sendable (String) async throws -> String
  let pullRequests:
    @Sendable (String, String?, PullRequestStatus?, String?, Int, BobbinSortOrder) async throws ->
      Page<PullRequestListItem>
  let authorPullRequests:
    @Sendable (String, String, String, PullRequestStatus?, String?, Int, BobbinSortOrder) async throws
      -> Page<PullRequestListItem>
  let viewPullRequest: @Sendable (String) async throws -> TangledRecord<PullRequest>
  let authoritativePullRequest: @Sendable (String) async throws -> TangledRecord<PullRequest>
  let comments: @Sendable (String, String?, Int) async throws -> Page<TangledRecord<Comment>>
  let coverage: @Sendable () async throws -> BobbinCoverage
  let pullRequestPatch: @Sendable (String, Int?) async throws -> PullRequestPatch
  let originURL: @Sendable () async throws -> String
  let defaultBranch: @Sendable (String) async throws -> GitDefaultBranch
  let prepare: @Sendable (String, String?, String) async throws -> PreparedPullRequest
  let prepareStack: @Sendable (String, String?, String) async throws -> PreparedPullRequestStack
  let create:
    @Sendable (String, String?, String, String, String, String?, Data) async throws ->
      TangledRecord<PullRequest>
  let createStack:
    @Sendable (String, String?, String, String, [PullRequestStackCommit]) async throws ->
      PullRequestStackCreationResult
  let prepareEdit: @Sendable (String) async throws -> PreparedPREdit
  let readEditBodyFile: @Sendable (String) throws -> String
  let prepareResubmission: @Sendable (String) async throws -> PreparedPRResubmission
  let prepareStackResubmission: @Sendable (String) async throws -> PreparedPRStackResubmission
  let createComment: @Sendable (RecordReference, String, Int) async throws -> TangledRecord<Comment>
  let mergeCheck: @Sendable (String) async throws -> PullRequestMergeCheck
  let merge: @Sendable (String, Bool) async throws -> PullRequestMergeResult
  let setStatus: @Sendable (String, PullRequestStatus) async throws -> TangledRecord<PullRequestStatusChange>

  static let live: PRCommandDependencies = {
    let client = BobbinClient()
    let locator = RepositoryLocator(client: client)
    let pdsRecordClient = PDSRecordClient()
    let authorPullRequestList = AuthorPullRequestListService(pdsRecordClient: pdsRecordClient)
    let recordReader = TangledRecordReader(
      pdsClient: pdsRecordClient,
      bobbinClient: client
    )
    let resubmissionService = PullRequestResubmissionService(
      pdsRecordClient: pdsRecordClient,
      repositoryLocator: locator
    )
    let stackResubmissionService = PullRequestStackResubmissionService(
      pdsRecordClient: pdsRecordClient,
      repositoryLocator: locator
    )
    let editService = PullRequestEditService(pdsRecordClient: pdsRecordClient)
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
      authorPullRequests: {
        repositoryDID, repositoryOwnerDID, authorDID, status, cursor, limit, order in
        try await authorPullRequestList.list(
          repositoryDID: repositoryDID,
          repositoryOwnerDID: repositoryOwnerDID,
          authorDID: authorDID,
          status: status,
          cursor: cursor,
          limit: limit,
          order: order
        )
      },
      viewPullRequest: { try await recordReader.pullRequest(uri: $0).record },
      authoritativePullRequest: { try await pdsRecordClient.pullRequest(uri: $0) },
      comments: { uri, cursor, limit in
        try await client.comments(subjectURI: uri, cursor: cursor, limit: limit)
      },
      coverage: { try await client.coverage() },
      pullRequestPatch: { uri, roundNumber in
        try await PullRequestPatchLoader(pdsRecordClient: pdsRecordClient).load(
          pullRequestURI: uri,
          roundNumber: roundNumber
        )
      },
      originURL: { try await GitOriginReader().read() },
      defaultBranch: { try await client.defaultBranch(repositoryURI: $0) },
      prepare: {
        try await GitPullRequestPreparer().prepare(base: $0, head: $1, baseRemote: $2)
      },
      prepareStack: {
        try await GitPullRequestPreparer().prepareStack(base: $0, head: $1, baseRemote: $2)
      },
      create: { repositoryDID, sourceRepositoryDID, base, head, title, body, patch in
        try await CLIAuthenticatedClient.make().createPullRequest(
          repositoryDID: repositoryDID,
          sourceRepositoryDID: sourceRepositoryDID,
          baseBranch: base,
          headBranch: head,
          title: title,
          body: body,
          patch: patch
        )
      },
      createStack: { repositoryDID, sourceRepositoryDID, base, head, commits in
        try await CLIAuthenticatedClient.make().createPullRequestStack(
          repositoryDID: repositoryDID,
          sourceRepositoryDID: sourceRepositoryDID,
          baseBranch: base,
          headBranch: head,
          commits: commits
        )
      },
      prepareEdit: { uri in
        let context = try await editService.prepare(pullRequestURI: uri)
        return PreparedPREdit(
          pullRequest: context.pullRequest,
          apply: { title, body in
            try await editService.edit(
              context,
              title: title,
              body: body,
              pdsClient: try await CLIAuthenticatedClient.make()
            )
          }
        )
      },
      readEditBodyFile: { try CLITextFileReader().read(path: $0) },
      prepareResubmission: {
        let context = try await resubmissionService.prepare(pullRequestURI: $0)
        return PreparedPRResubmission(
          pullRequest: context.pullRequest,
          submitBranch: { patch, sourceRevision in
            try await resubmissionService.resubmit(
              context,
              patch: patch,
              sourceRevision: sourceRevision,
              pdsClient: try await CLIAuthenticatedClient.make()
            )
          },
          submitPatch: { patch in
            try await resubmissionService.resubmit(
              context,
              patch: patch,
              pdsClient: try await CLIAuthenticatedClient.make()
            )
          },
          submitFork: {
            try await resubmissionService.resubmitFork(
              context,
              pdsClient: try await CLIAuthenticatedClient.make()
            )
          }
        )
      },
      prepareStackResubmission: { uri in
        let context = try await stackResubmissionService.prepare(pullRequestURI: uri)
        return PreparedPRStackResubmission(
          pullRequest: context.pullRequest,
          forkCommits: {
            try await stackResubmissionService.forkCommits(
              context,
              pdsClient: try await CLIAuthenticatedClient.make()
            )
          },
          makePlan: { commits in
            let prepared = try await stackResubmissionService.plan(context, commits: commits)
            return PreparedPRStackPlan(
              plan: prepared.plan,
              apply: {
                try await CLIAuthenticatedClient.make()
                  .applyPullRequestStackResubmission(prepared)
              }
            )
          }
        )
      },
      createComment: { subject, body, roundIndex in
        try await CLIAuthenticatedClient.make().createComment(
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
          pdsClient: try await CLIAuthenticatedClient.make()
        )
      },
      setStatus: { uri, status in
        try await CLIAuthenticatedClient.make().setPullRequestStatus(
          uri,
          status: status
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
    let reference = if let repository { repository } else { try await dependencies.originURL() }
    let repositoryRecord = try await dependencies.resolveRepository(reference)
    guard let repositoryDID = repositoryRecord.value.repoDID, !repositoryDID.isEmpty else {
      throw TangledError.invalidRequest(
        "repository does not expose a repository DID: \(repositoryRecord.uri)"
      )
    }
    if let author {
      let authorDID = try await dependencies.resolveOwnerDID(author)
      let repositoryOwnerDID = try repositoryOwnerDID(repositoryRecord.uri)
      let page = try await dependencies.authorPullRequests(
        repositoryDID,
        repositoryOwnerDID,
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
    async let coverage = readBobbinCoverage(using: dependencies.coverage)
    let page = try await dependencies.pullRequests(
      repositoryDID,
      nil,
      status,
      cursor,
      limit,
      sort
    )
    return CLICommandOutput(
      stdout: try json ? formatter.json(page) : format(page.items),
      stderr:
        formatter.cursorDiagnostic(page.cursor, json: json)
        + BobbinReadDiagnostics(
          coverage: try await coverage,
          initialPageIsEmpty: cursor == nil && page.items.isEmpty
        ).stderr
    )
  }

  private func repositoryOwnerDID(_ repositoryURI: String) throws -> String {
    let owner =
      repositoryURI.removingPrefix("at://").split(separator: "/", maxSplits: 1)
      .first.map(String.init)
    guard let owner, owner.hasPrefix("did:") else {
      throw TangledError.invalidRequest(
        "repository record does not expose an owner DID: \(repositoryURI)"
      )
    }
    return owner
  }

  func view(
    pullRequestURI: String,
    comments: Bool = false,
    commentLimit: Int = 30,
    commentCursor: String? = nil,
    json: Bool
  ) async throws -> CLICommandOutput {
    let record = try await dependencies.viewPullRequest(pullRequestURI)
    guard comments else {
      return CLICommandOutput(
        stdout: try json ? formatter.json(record) : format(record),
        isPageable: !json
      )
    }
    async let coverage = readBobbinCoverage(using: dependencies.coverage)
    let page = try await dependencies.comments(pullRequestURI, commentCursor, commentLimit)
    let result = PRViewWithCommentsResult(pullRequest: record, comments: page)
    return CLICommandOutput(
      stdout: try json ? formatter.json(result) : format(record) + format(page.items),
      stderr:
        formatter.cursorDiagnostic(page.cursor, json: json)
        + BobbinReadDiagnostics(
          coverage: try await coverage,
          initialPageIsEmpty: commentCursor == nil && page.items.isEmpty
        ).stderr,
      isPageable: !json
    )
  }

  func comment(
    pullRequestURI: String,
    body: String?,
    bodyFile: String?,
    roundNumber: Int?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let pullRequest = try await dependencies.authoritativePullRequest(pullRequestURI)
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
    return CLICommandOutput(stdoutData: patch.unifiedDiff, isPageable: true)
  }

  func edit(
    pullRequestURI: String,
    title: String?,
    body: String?,
    bodyFile: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let prepared = try await dependencies.prepareEdit(pullRequestURI)
    let resolvedBody: String?
    if let bodyFile {
      resolvedBody = try dependencies.readEditBodyFile(bodyFile)
    } else if let body {
      resolvedBody = body
    } else {
      resolvedBody = prepared.pullRequest.value.body
    }
    let record = try await prepared.apply(
      title ?? prepared.pullRequest.value.title,
      resolvedBody
    )
    return CLICommandOutput(stdout: try json ? formatter.json(record) : format(record))
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

  func setStatus(
    pullRequestURI: String,
    status: PullRequestStatus,
    json: Bool
  ) async throws -> CLICommandOutput {
    let record = try await dependencies.setStatus(pullRequestURI, status)
    return CLICommandOutput(stdout: try json ? formatter.json(record) : format(record))
  }

  func create(
    repository: String?,
    base: String?,
    head: String?,
    title: String?,
    body: String?,
    bodyFile: String?,
    stack: Bool = false,
    json: Bool
  ) async throws -> CLICommandOutput {
    let origin = try await dependencies.originURL()
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
    if stack {
      guard title == nil, body == nil, bodyFile == nil else {
        throw TangledError.invalidRequest(
          "--stack cannot be used with --title, --body, or --body-file"
        )
      }
      let prepared = try await dependencies.prepareStack(resolvedBase, head, baseRemote)
      let created = try await dependencies.createStack(
        targetDID,
        isFork ? originDID : nil,
        prepared.base,
        prepared.head,
        prepared.commits
      )
      let result = PRCreateStackResult(
        pullRequests: created.pullRequests,
        repositoryPullsURL: repositoryPullsURL(record: targetRecord)
      )
      return CLICommandOutput(
        stdout: try json ? formatter.json(result) : format(result)
      )
    }
    let prepared = try await dependencies.prepare(resolvedBase, head, baseRemote)
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

  func resubmit(
    pullRequestURI: String,
    patchFile: String? = nil,
    stack: Bool = false,
    dryRun: Bool = false,
    confirmed: Bool = false,
    json: Bool
  ) async throws -> CLICommandOutput {
    if stack {
      return try await resubmitStack(
        pullRequestURI: pullRequestURI,
        patchFile: patchFile,
        dryRun: dryRun,
        confirmed: confirmed,
        json: json
      )
    }
    guard !dryRun, !confirmed else {
      throw TangledError.invalidRequest("--dry-run and --yes require --stack")
    }
    let resubmission = try await dependencies.prepareResubmission(pullRequestURI)
    let pull = resubmission.pullRequest.value
    let result: PullRequestResubmissionResult
    if pull.source == nil {
      guard let patchFile else {
        throw TangledError.invalidRequest(
          "patch-based pull request resubmission requires --patch-file"
        )
      }
      let patch: Data
      do throws(TangledError) {
        patch = try PatchFileReader().read(path: patchFile)
      } catch {
        throw error
      }
      result = try await resubmission.submitPatch(patch)
    } else if let source = pull.source, let sourceRepositoryDID = source.repositoryDID {
      guard patchFile == nil else {
        throw TangledError.invalidRequest(
          "--patch-file is not valid for fork-based pull requests"
        )
      }
      let origin = try await dependencies.originURL()
      let originRecord = try await dependencies.resolveRepository(origin)
      guard originRecord.value.repoDID == sourceRepositoryDID else {
        throw TangledError.invalidRequest(
          "Git origin does not match the pull request source repository"
        )
      }
      result = try await resubmission.submitFork()
    } else {
      guard patchFile == nil else {
        throw TangledError.invalidRequest(
          "--patch-file is only valid for patch-based pull requests"
        )
      }
      guard let source = pull.source else {
        throw TangledError.invalidRequest("pull request source is missing")
      }
      let origin = try await dependencies.originURL()
      let originRecord = try await dependencies.resolveRepository(origin)
      guard originRecord.value.repoDID == pull.target.repositoryDID else {
        throw TangledError.invalidRequest(
          "Git origin does not match the pull request target repository"
        )
      }
      let prepared = try await dependencies.prepare(
        pull.target.branch,
        source.branch,
        "origin"
      )
      result = try await resubmission.submitBranch(
        prepared.patch,
        prepared.sourceRevision
      )
    }
    return CLICommandOutput(
      stdout: try json ? formatter.json(result) : format(result)
    )
  }

  private func resubmitStack(
    pullRequestURI: String,
    patchFile: String?,
    dryRun: Bool,
    confirmed: Bool,
    json: Bool
  ) async throws -> CLICommandOutput {
    guard !(dryRun && confirmed) else {
      throw TangledError.invalidRequest("--dry-run cannot be combined with --yes")
    }
    let prepared = try await dependencies.prepareStackResubmission(pullRequestURI)
    let pull = prepared.pullRequest.value
    let commits: [PullRequestStackCommit]
    if pull.source == nil {
      guard let patchFile else {
        throw TangledError.invalidRequest(
          "patch-based stack resubmission requires --patch-file"
        )
      }
      do throws(TangledError) {
        commits = try FormatPatchSeries.parse(PatchFileReader().read(path: patchFile))
      } catch {
        throw error
      }
    } else if let source = pull.source, let sourceRepositoryDID = source.repositoryDID {
      guard patchFile == nil else {
        throw TangledError.invalidRequest(
          "--patch-file is not valid for fork-based stack resubmission"
        )
      }
      let origin = try await dependencies.originURL()
      let originRecord = try await dependencies.resolveRepository(origin)
      guard originRecord.value.repoDID == sourceRepositoryDID else {
        throw TangledError.invalidRequest(
          "Git origin does not match the pull request source repository"
        )
      }
      commits = try await prepared.forkCommits()
    } else {
      guard patchFile == nil, let source = pull.source else {
        throw TangledError.invalidRequest(
          "--patch-file is only valid for patch-based stack resubmission"
        )
      }
      let origin = try await dependencies.originURL()
      let originRecord = try await dependencies.resolveRepository(origin)
      guard originRecord.value.repoDID == pull.target.repositoryDID else {
        throw TangledError.invalidRequest(
          "Git origin does not match the pull request target repository"
        )
      }
      commits = try await dependencies.prepareStack(
        pull.target.branch,
        source.branch,
        "origin"
      ).commits
    }
    let plan = try await prepared.makePlan(commits)
    if dryRun {
      return CLICommandOutput(
        stdout: try json ? formatter.json(plan.plan) : format(plan.plan)
      )
    }
    guard !plan.plan.requiresConfirmation || confirmed else {
      throw TangledError.invalidRequest(
        "stack resubmission deletes pull request records; inspect with --dry-run and rerun with --yes"
      )
    }
    let result = try await plan.apply()
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
    if result.outcome == .mergedStatusRecordsFailed {
      let uris = result.check.pullRequestURIs.joined(separator: ", ")
      return """
        Merge succeeded: \(uris)
        Merged status records were not written: \(result.statusRecordError ?? "unknown error")
        Do not rerun `tng pr merge` for \(uris); inspect these Pull Requests and repair their merged status records separately.
        """
          + "\n"
    }
    return formatter.details([
      ("Merged", result.check.pullRequestURIs.joined(separator: ", ")),
      ("Target", "\(result.check.repositoryDID):\(result.check.targetBranch)"),
      ("Status records", String(result.statusRecords.count)),
    ])
  }

  fileprivate func format(_ record: TangledRecord<PullRequestStatusChange>) -> String {
    formatter.details([
      ("URI", record.uri),
      ("CID", record.cid),
      ("Pull request", record.value.pullRequestURI),
      ("Status", record.value.status.rawValue),
      ("Created", record.value.createdAt.rawValue),
    ])
  }

  fileprivate func format(_ result: PRCreateResult) -> String {
    "Created pull request: \(result.pullRequest.uri)\n"
      + "Pull requests: \(result.repositoryPullsURL)\n"
  }

  fileprivate func format(_ result: PRCreateStackResult) -> String {
    var output = "Created \(result.pullRequests.count) pull requests:\n"
    for (index, pullRequest) in result.pullRequests.enumerated() {
      output += "\(index): \(pullRequest.uri)"
      if let dependentOn = pullRequest.value.dependentOn {
        output += " (depends on \(dependentOn))"
      }
      output += "\n"
    }
    return output + "Pull requests: \(result.repositoryPullsURL)\n"
  }

  fileprivate func format(_ result: PullRequestResubmissionResult) -> String {
    "Resubmitted pull request: \(result.pullRequest.uri)\n"
      + "Round: \(result.roundNumber)\n"
  }

  fileprivate func format(_ plan: PullRequestStackResubmissionPlan) -> String {
    formatter.table(
      headers: ["OPERATION", "CHANGE ID", "URI", "ROUND", "DEPENDENT ON"],
      rows: plan.operations.map {
        [
          $0.kind.rawValue,
          $0.changeID,
          $0.pullRequestURI,
          $0.roundNumber.map(String.init) ?? "",
          $0.dependentOn ?? "",
        ]
      }
    )
  }

  fileprivate func format(_ result: PullRequestStackResubmissionResult) -> String {
    format(result.plan)
      + "Resubmitted pull requests: \(result.pullRequests.count)\n"
      + "Deleted pull requests: \(result.deletedPullRequestURIs.count)\n"
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
        item.commentCount >= 0 ? String(item.commentCount) : "-",
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
    return formatter.details(
      fields + roundFields(pullRequest.rounds),
      markdownLabels: ["Body"]
    )
  }

  fileprivate func format(_ comments: [TangledRecord<Comment>]) -> String {
    guard !comments.isEmpty else {
      return "\nComments\nNo comments.\n"
    }
    let rows = comments.map { record in
      [
        record.uri,
        record.value.context.pullRequestRoundIndex.map(String.init) ?? "",
        record.value.body.displayText,
        record.value.createdAt.rawValue,
      ]
    }
    return "\nComments\n"
      + formatter.table(
        headers: ["URI", "ROUND", "BODY", "CREATED"],
        rows: rows,
        markdownColumns: [2]
      )
  }

  fileprivate func format(_ record: TangledRecord<Comment>) -> String {
    formatter.details(
      [
        ("URI", record.uri),
        ("CID", record.cid),
        ("Subject", record.value.context.subject.uri),
        ("Round", record.value.context.pullRequestRoundIndex.map(String.init)),
        ("Body", record.value.body.displayText),
        ("Created", record.value.createdAt.rawValue),
      ],
      markdownLabels: ["Body"]
    )
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

struct PRCreateStackResult: Codable, Equatable, Sendable {
  let pullRequests: [TangledRecord<PullRequest>]
  let repositoryPullsURL: String
}

struct PreparedPRResubmission: Sendable {
  let pullRequest: TangledRecord<PullRequest>
  let submitBranch: @Sendable (Data, String) async throws -> PullRequestResubmissionResult
  let submitPatch: @Sendable (Data) async throws -> PullRequestResubmissionResult
  let submitFork: @Sendable () async throws -> PullRequestResubmissionResult
}

struct PreparedPREdit: Sendable {
  let pullRequest: TangledRecord<PullRequest>
  let apply: @Sendable (String, String?) async throws -> TangledRecord<PullRequest>
}

struct PreparedPRStackResubmission: Sendable {
  let pullRequest: TangledRecord<PullRequest>
  let forkCommits: @Sendable () async throws -> [PullRequestStackCommit]
  let makePlan: @Sendable ([PullRequestStackCommit]) async throws -> PreparedPRStackPlan
}

struct PreparedPRStackPlan: Sendable {
  let plan: PullRequestStackResubmissionPlan
  let apply: @Sendable () async throws -> PullRequestStackResubmissionResult
}

struct PRViewWithCommentsResult: Codable, Equatable, Sendable {
  let pullRequest: TangledRecord<PullRequest>
  let comments: Page<TangledRecord<Comment>>
}
