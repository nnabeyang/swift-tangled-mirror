import Foundation
import OAuth4Swift
import SwiftAtproto
import TangledLexicons

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct PDSClient: Sendable {
  private static let starCollection = "sh.tangled.feed.star"
  private static let issueCollection = "sh.tangled.repo.issue"
  private static let issueStateCollection = "sh.tangled.repo.issue.state"
  private static let pullCollection = "sh.tangled.repo.pull"
  private static let commentCollection = "sh.tangled.feed.comment"
  private static let pullStatusCollection = "sh.tangled.repo.pull.status"

  package let client: any XRPCCallable
  package let repoDID: String
  package let grantedScopes: ScopesSet
  package let now: @Sendable () -> Date
  package let nextRecordKey: @Sendable () -> String
  private let retainedSessionStore: SessionStoreBox?

  public static func restore(from sessionStore: any SessionStore) throws -> PDSClient {
    guard let storedSession = try sessionStore.load() else {
      throw TangledError.unauthorized
    }

    let agent = try AtprotoOAuthAgent(
      archive: .init(did: storedSession.did, session: storedSession.archive),
      clientId: OAuth.ClientInfo.tangledCLI.clientId,
      authFetcher: URLSession.manualRedirect(),
      atprotoResolver: URLSessionATPResolver(),
      delegate: sessionStore
    )
    return PDSClient(
      client: agent,
      repoDID: storedSession.did,
      authorizedScopes: storedSession.archive.tokenState.authorizedScopes,
      retainedSessionStore: SessionStoreBox(sessionStore)
    )
  }

  init(
    client: any XRPCCallable,
    repoDID: String,
    authorizedScopes: [String],
    now: @escaping @Sendable () -> Date = Date.init,
    nextRecordKey: @escaping @Sendable () -> String = { TID.next().rawValue }
  ) {
    self.init(
      client: client,
      repoDID: repoDID,
      authorizedScopes: authorizedScopes,
      now: now,
      nextRecordKey: nextRecordKey,
      retainedSessionStore: nil
    )
  }

  private init(
    client: any XRPCCallable,
    repoDID: String,
    authorizedScopes: [String],
    now: @escaping @Sendable () -> Date = Date.init,
    nextRecordKey: @escaping @Sendable () -> String = { TID.next().rawValue },
    retainedSessionStore: SessionStoreBox?
  ) {
    self.client = client
    self.repoDID = repoDID
    self.grantedScopes = ScopesSet(rawScopes: authorizedScopes)
    self.now = now
    self.nextRecordKey = nextRecordKey
    self.retainedSessionStore = retainedSessionStore
  }

  public func star(repositoryDID: String) async throws -> TangledRecord<Star> {
    let repositoryDID = try validatedDID(repositoryDID)
    try requireStarScope(action: .update)

    let records = try await starRecords()
    if let existing = records.first(where: {
      $0.value.subject == .repository(did: repositoryDID)
    }) {
      return existing
    }

    let createdAt = FormatString(now())
    let record = Sh.Tangled.FeedStar(
      createdAt: createdAt,
      subject: .feedStarRepo(.init(did: FormatString(rawValue: repositoryDID)))
    )
    let input = Com.Atproto.RepoPutRecord_Input(
      collection: FormatString(rawValue: Self.starCollection),
      record: .record(record),
      repo: FormatString(rawValue: repoDID),
      rkey: FormatString(rawValue: nextRecordKey()),
      // Tangled Web leaves this unset. Requiring validation makes PDSes that do not
      // register the Tangled Lexicon reject an otherwise valid custom record.
      validate: nil
    )
    let output = try await perform {
      try await client.RepoPutRecord(input: input)
    }
    return TangledRecord(
      uri: output.uri.rawValue,
      cid: output.cid.rawValue,
      value: Star(subject: .repository(did: repositoryDID), createdAt: createdAt)
    )
  }

  public func createIssue(
    repositoryDID: String,
    title: String,
    body: String? = nil
  ) async throws -> TangledRecord<Issue> {
    let repositoryDID = try validatedDID(repositoryDID)
    let title = try validatedNonempty(title, name: "issue title")
    let body = body?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    guard grantedScopes.allowsRepo(collection: Self.issueCollection, action: .update) else {
      throw TangledError.insufficientScope("repo:\(Self.issueCollection)")
    }

    let createdAt = FormatString(now())
    let record = Sh.Tangled.RepoIssue(
      body: body,
      createdAt: createdAt,
      mentions: [],
      references: [],
      repo: FormatString(rawValue: repositoryDID),
      title: title
    )
    let input = Com.Atproto.RepoPutRecord_Input(
      collection: FormatString(rawValue: Self.issueCollection),
      record: .record(record),
      repo: FormatString(rawValue: repoDID),
      rkey: FormatString(rawValue: nextRecordKey()),
      validate: nil
    )
    let output = try await perform {
      try await client.RepoPutRecord(input: input)
    }
    return TangledRecord(
      uri: output.uri.rawValue,
      cid: output.cid.rawValue,
      value: Issue(
        repositoryDID: repositoryDID,
        title: title,
        body: body,
        createdAt: createdAt
      )
    )
  }

  public func updateIssue(
    current: TangledRecord<Issue>,
    title: String,
    body: String?
  ) async throws -> TangledRecord<Issue> {
    let uri = try validatedIssueURI(current.uri)
    guard uri.authority.rawValue == repoDID else {
      throw TangledError.invalidRequest("only the Issue owner can edit this Issue")
    }
    guard let currentCID = current.cid, !currentCID.isEmpty else {
      throw TangledError.invalidRequest("Issue does not expose a CID")
    }
    let title = try validatedNonempty(title, name: "issue title")
    let body = body?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    guard grantedScopes.allowsRepo(collection: Self.issueCollection, action: .update) else {
      throw TangledError.insufficientScope("repo:\(Self.issueCollection)")
    }

    let issue = current.value
    let record = Sh.Tangled.RepoIssue(
      body: body,
      createdAt: issue.createdAt,
      mentions: issue.mentions.map(FormatString.init(rawValue:)),
      references: issue.references.map(FormatString.init(rawValue:)),
      repo: FormatString(rawValue: issue.repositoryDID),
      title: title
    )
    let input = Com.Atproto.RepoPutRecord_Input(
      collection: FormatString(rawValue: Self.issueCollection),
      record: .record(record),
      repo: FormatString(rawValue: repoDID),
      rkey: FormatString(uri.rkey!),
      swapRecord: FormatString(rawValue: currentCID),
      validate: nil
    )
    let output = try await perform {
      try await client.RepoPutRecord(input: input)
    }
    return TangledRecord(
      uri: output.uri.rawValue,
      cid: output.cid.rawValue,
      value: Issue(
        repositoryDID: issue.repositoryDID,
        title: title,
        body: body,
        createdAt: issue.createdAt,
        mentions: issue.mentions,
        references: issue.references
      )
    )
  }

  public func setIssueState(
    issueURI: String,
    state: IssueStatus
  ) async throws -> TangledRecord<IssueState> {
    _ = try validatedIssueURI(issueURI)
    let wireState: Sh.Tangled.Repo.IssueState_State
    switch state {
    case .open:
      wireState = .shTangledRepoIssueStateOpen
    case .closed:
      wireState = .shTangledRepoIssueStateClosed
    default:
      throw TangledError.invalidRequest("issue state must be open or closed")
    }
    guard grantedScopes.allowsRepo(collection: Self.issueStateCollection, action: .update) else {
      throw TangledError.insufficientScope("repo:\(Self.issueStateCollection)")
    }

    let createdAt = FormatString(now())
    let record = Sh.Tangled.Repo.IssueState(
      createdAt: createdAt,
      issue: FormatString(rawValue: issueURI),
      state: wireState
    )
    let input = Com.Atproto.RepoPutRecord_Input(
      collection: FormatString(rawValue: Self.issueStateCollection),
      record: .record(record),
      repo: FormatString(rawValue: repoDID),
      rkey: FormatString(rawValue: nextRecordKey()),
      validate: nil
    )
    let output = try await perform {
      try await client.RepoPutRecord(input: input)
    }
    return TangledRecord(
      uri: output.uri.rawValue,
      cid: output.cid.rawValue,
      value: IssueState(issueURI: issueURI, state: state, createdAt: createdAt)
    )
  }

  public func createPullRequest(
    repositoryDID: String,
    sourceRepositoryDID: String? = nil,
    baseBranch: String,
    headBranch: String,
    title: String,
    body: String? = nil,
    patch: Data
  ) async throws -> TangledRecord<PullRequest> {
    let repositoryDID = try validatedDID(repositoryDID)
    let sourceRepositoryDID = try sourceRepositoryDID.map(validatedDID)
    let isFork = sourceRepositoryDID != nil && sourceRepositoryDID != repositoryDID
    let baseBranch = try validatedNonempty(baseBranch, name: "base branch")
    let headBranch = try validatedNonempty(headBranch, name: "head branch")
    let title = try validatedNonempty(title, name: "title")
    guard isFork || baseBranch != headBranch else {
      throw TangledError.invalidRequest("base and head branches must differ")
    }
    try requirePullScope()

    let compressedPatch = try GzipCompressor.compress(patch)
    let upload = try await perform {
      try await client.RepoUploadBlob(
        input: XRPCBlobUpload(data: compressedPatch, mimeType: "application/gzip")
      )
    }
    let createdAt = FormatString(now())
    let record = Sh.Tangled.RepoPull(
      body: body?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      createdAt: createdAt,
      mentions: [],
      references: [],
      rounds: [.init(createdAt: createdAt, patchBlob: upload.blob)],
      source: .init(
        branch: headBranch,
        repo: isFork ? FormatString(rawValue: sourceRepositoryDID!) : nil
      ),
      target: .init(branch: baseBranch, repo: FormatString(rawValue: repositoryDID)),
      title: title
    )
    let input = Com.Atproto.RepoPutRecord_Input(
      collection: FormatString(rawValue: Self.pullCollection),
      record: .record(record),
      repo: FormatString(rawValue: repoDID),
      rkey: FormatString(rawValue: nextRecordKey()),
      validate: nil
    )
    let output: Com.Atproto.RepoPutRecord_Output
    do {
      output = try await perform {
        try await client.RepoPutRecord(input: input)
      }
    } catch {
      throw TangledError.transport(
        "\(error.localizedDescription) (uploaded patch blob: \(upload.blob.ref.toBaseEncodedString))"
      )
    }
    return TangledRecord(
      uri: output.uri.rawValue,
      cid: output.cid.rawValue,
      value: PullRequest(
        title: title,
        body: record.body,
        rounds: [
          .init(
            createdAt: createdAt,
            patchBlob: .init(
              cid: upload.blob.ref.toBaseEncodedString,
              mimeType: upload.blob.mimeType,
              size: Int(upload.blob.size)
            )
          )
        ],
        source: .init(
          branch: headBranch,
          repositoryDID: isFork ? sourceRepositoryDID : nil
        ),
        target: .init(branch: baseBranch, repositoryDID: repositoryDID),
        createdAt: createdAt,
        mentions: [],
        references: [],
      )
    )
  }

  func appendPullRequestRound(
    current: PullRequestRecordSnapshot,
    patch: Data
  ) async throws -> TangledRecord<PullRequest> {
    let uri: ATURI
    do {
      uri = try ATURI(string: current.record.uri)
    } catch {
      throw TangledError.invalidRequest("invalid pull request AT URI")
    }
    guard case .did(let ownerDID) = uri.authority,
      ownerDID.rawValue == repoDID
    else {
      throw TangledError.invalidRequest(
        "only the Pull Request owner can resubmit it"
      )
    }
    guard uri.collection?.rawValue == Self.pullCollection,
      let rkey = uri.rkey
    else {
      throw TangledError.invalidRequest(
        "pull request URI must identify a \(Self.pullCollection) record"
      )
    }
    guard let currentCID = current.record.cid, !currentCID.isEmpty else {
      throw TangledError.invalidRequest("pull request does not expose a CID")
    }
    try requirePullScope()

    let compressedPatch = try GzipCompressor.compress(patch)
    let upload = try await perform {
      try await client.RepoUploadBlob(
        input: XRPCBlobUpload(data: compressedPatch, mimeType: "application/gzip")
      )
    }
    let createdAt = FormatString(now())
    let rawRecord = try appendingRound(
      to: current.rawValue,
      createdAt: createdAt,
      blob: upload.blob
    )
    let input = Com.Atproto.RepoPutRecord_Input(
      collection: FormatString(rawValue: Self.pullCollection),
      record: rawRecord,
      repo: FormatString(rawValue: repoDID),
      rkey: FormatString(rkey),
      swapRecord: FormatString(rawValue: currentCID),
      validate: nil
    )
    let output = try await perform {
      try await client.RepoPutRecord(input: input)
    }
    guard output.uri.rawValue == current.record.uri else {
      throw TangledError.upstreamFailed(
        "PDS returned a different pull request record: \(output.uri.rawValue)"
      )
    }
    return try TangledRecordDecoder.pullRequest(
      uri: output.uri.rawValue,
      cid: output.cid.rawValue,
      value: rawRecord
    )
  }

  public func createComment(
    subject: RecordReference,
    body: String,
    pullRequestRoundIndex: Int? = nil,
    replyTo: RecordReference? = nil
  ) async throws -> TangledRecord<Comment> {
    let body = try validatedNonempty(body, name: "comment body")
    let subject = try validatedStrongReference(subject, name: "comment subject")
    let replyTo = try replyTo.map {
      try validatedStrongReference($0, name: "reply target")
    }
    if let pullRequestRoundIndex, pullRequestRoundIndex < 0 {
      throw TangledError.invalidRequest("pull request round index must not be negative")
    }
    guard grantedScopes.allowsRepo(collection: Self.commentCollection, action: .update) else {
      throw TangledError.insufficientScope("repo:\(Self.commentCollection)")
    }

    let createdAt = FormatString(now())
    let record = Sh.Tangled.FeedComment(
      body: .markupMarkdown(.init(original: body, text: body)),
      createdAt: createdAt,
      pullRoundIdx: pullRequestRoundIndex,
      replyTo: replyTo,
      subject: subject
    )
    let input = Com.Atproto.RepoPutRecord_Input(
      collection: FormatString(rawValue: Self.commentCollection),
      record: .record(record),
      repo: FormatString(rawValue: repoDID),
      rkey: FormatString(rawValue: nextRecordKey()),
      validate: nil
    )
    let output = try await perform {
      try await client.RepoPutRecord(input: input)
    }
    return TangledRecord(
      uri: output.uri.rawValue,
      cid: output.cid.rawValue,
      value: Comment(
        context: CommentContext(
          subject: RecordReference(
            uri: subject.uri.rawValue,
            cid: subject.cid.rawValue
          ),
          replyTo: replyTo.map {
            RecordReference(uri: $0.uri.rawValue, cid: $0.cid.rawValue)
          },
          pullRequestRoundIndex: pullRequestRoundIndex
        ),
        body: MarkdownContent(text: body, original: body),
        createdAt: createdAt
      )
    )
  }

  public func serviceAuthToken(audience: String, lxm: String) async throws -> String {
    let audience = try validatedNonempty(audience, name: "service audience")
    let lxm = try validatedNonempty(lxm, name: "service method")
    guard grantedScopes.allowsRpc(lxm: lxm, aud: audience) else {
      throw TangledError.insufficientScope("rpc:\(lxm)?aud=\(audience)")
    }
    let output = try await perform {
      try await client.ServerGetServiceAuth(
        aud: audience,
        lxm: FormatString(rawValue: lxm)
      )
    }
    return output.token
  }

  public func markPullRequestsMerged(
    _ pullRequestURIs: [String]
  ) async throws -> [TangledRecord<PullRequestStatusChange>] {
    try await setPullRequestStatuses(pullRequestURIs, status: .merged)
  }

  public func setPullRequestStatus(
    _ pullRequestURI: String,
    status: PullRequestStatus
  ) async throws -> TangledRecord<PullRequestStatusChange> {
    guard let record = try await setPullRequestStatuses([pullRequestURI], status: status).first else {
      throw TangledError.decoding(PDSClientError.invalidApplyWritesResult)
    }
    return record
  }

  public func setPullRequestStatuses(
    _ pullRequestURIs: [String],
    status: PullRequestStatus
  ) async throws -> [TangledRecord<PullRequestStatusChange>] {
    guard !pullRequestURIs.isEmpty else { return [] }
    guard grantedScopes.allowsRepo(collection: Self.pullStatusCollection, action: .update) else {
      throw TangledError.insufficientScope("repo:\(Self.pullStatusCollection)")
    }
    let wireStatus: Sh.Tangled.Repo.PullStatus_Status
    switch status {
    case .open:
      wireStatus = .shTangledRepoPullStatusOpen
    case .closed:
      wireStatus = .shTangledRepoPullStatusClosed
    case .merged:
      wireStatus = .shTangledRepoPullStatusMerged
    default:
      throw TangledError.invalidRequest("invalid pull request status: \(status.rawValue)")
    }
    let createdAt = FormatString(now())
    let records = try pullRequestURIs.map { uri -> (String, Sh.Tangled.Repo.PullStatus) in
      guard let parsed = FormatString<ATURI>(rawValue: uri).typed,
        parsed.collection?.rawValue == Self.pullCollection,
        parsed.rkey != nil
      else {
        throw TangledError.invalidRequest("invalid pull request AT URI: \(uri)")
      }
      return (
        nextRecordKey(),
        Sh.Tangled.Repo.PullStatus(
          createdAt: createdAt,
          pull: FormatString(rawValue: uri),
          status: wireStatus
        )
      )
    }
    let writes = records.map { rkey, record in
      Com.Atproto.RepoApplyWrites_Input_Writes_Elem.repoApplyWritesCreate(
        .init(
          collection: FormatString(rawValue: Self.pullStatusCollection),
          rkey: FormatString(rawValue: rkey),
          value: .record(record)
        )
      )
    }
    let output = try await perform {
      try await client.RepoApplyWrites(
        input: .init(
          repo: FormatString(rawValue: repoDID),
          validate: nil,
          writes: writes
        )
      )
    }
    guard let results = output.results, results.count == records.count else {
      throw TangledError.decoding(PDSClientError.invalidApplyWritesResult)
    }
    return try zip(pullRequestURIs, results).map { uri, result in
      guard case .repoApplyWritesCreateResult(let created) = result else {
        throw TangledError.decoding(PDSClientError.invalidApplyWritesResult)
      }
      return TangledRecord(
        uri: created.uri.rawValue,
        cid: created.cid.rawValue,
        value: PullRequestStatusChange(
          pullRequestURI: uri,
          status: status,
          createdAt: createdAt
        )
      )
    }
  }

  @discardableResult
  public func unstar(repositoryDID: String) async throws -> Bool {
    let repositoryDID = try validatedDID(repositoryDID)
    try requireStarScope(action: .delete)

    let matches = try await starRecords().filter {
      $0.value.subject == .repository(did: repositoryDID)
    }
    guard !matches.isEmpty else {
      return false
    }

    for record in matches {
      guard let rkey = FormatString<ATURI>(rawValue: record.uri).typed?.rkey else {
        throw TangledError.decoding(
          PDSClientError.invalidRecordURI(record.uri)
        )
      }
      let input = Com.Atproto.RepoDeleteRecord_Input(
        collection: FormatString(rawValue: Self.starCollection),
        repo: FormatString(rawValue: repoDID),
        rkey: FormatString(rkey)
      )
      _ = try await perform {
        try await client.RepoDeleteRecord(input: input)
      }
    }
    return true
  }
}

extension PDSClient {
  private func appendingRound(
    to record: UnknownATPValue,
    createdAt: FormatString<Date>,
    blob: LexBlob
  ) throws -> UnknownATPValue {
    let data = try JSONEncoder().encode(record)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      var rounds = object["rounds"] as? [Any]
    else {
      throw TangledError.decoding(PDSClientError.invalidPullRequestRecord)
    }
    let blobObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(blob))
    rounds.append([
      "createdAt": createdAt.rawValue,
      "patchBlob": blobObject,
    ])
    object["rounds"] = rounds
    let updated = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.userInfo[.atprotoLexiconDecodingMode] = LexiconDecodingMode.permissive
    return try decoder.decode(UnknownATPValue.self, from: updated)
  }

  private func validatedDID(_ value: String) throws -> String {
    do {
      return try DID(string: value).rawValue
    } catch {
      throw TangledError.invalidRequest("invalid repository DID: \(value)")
    }
  }

  private func requireStarScope(action: LexPermissionAction) throws {
    guard grantedScopes.allowsRepo(collection: Self.starCollection, action: action) else {
      throw TangledError.insufficientScope("repo:\(Self.starCollection)")
    }
  }

  private func requirePullScope() throws {
    guard grantedScopes.allowsRepo(collection: Self.pullCollection, action: .update) else {
      throw TangledError.insufficientScope("repo:\(Self.pullCollection)")
    }
  }

  private func validatedNonempty(_ value: String, name: String) throws -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      throw TangledError.invalidRequest("\(name) must not be empty")
    }
    return value
  }

  private func validatedIssueURI(_ value: String) throws -> ATURI {
    guard let uri = FormatString<ATURI>(rawValue: value).typed,
      uri.collection?.rawValue == Self.issueCollection,
      uri.rkey != nil
    else {
      throw TangledError.invalidRequest("invalid Issue AT URI: \(value)")
    }
    return uri
  }

  private func validatedStrongReference(
    _ reference: RecordReference,
    name: String
  ) throws -> Com.Atproto.RepoStrongRef {
    guard FormatString<ATURI>(rawValue: reference.uri).typed != nil else {
      throw TangledError.invalidRequest("\(name) has an invalid AT URI: \(reference.uri)")
    }
    guard !reference.cid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TangledError.invalidRequest("\(name) CID must not be empty")
    }
    return .init(
      cid: FormatString(rawValue: reference.cid),
      uri: FormatString(rawValue: reference.uri)
    )
  }

  private func starRecords() async throws -> [TangledRecord<Star>] {
    var cursor: String?
    var seenCursors = Set<String>()
    var records: [TangledRecord<Star>] = []

    repeat {
      let output = try await perform {
        try await client.RepoListRecords(
          collection: FormatString(rawValue: Self.starCollection),
          cursor: cursor,
          limit: 100,
          repo: FormatString(rawValue: repoDID),
          reverse: nil
        )
      }
      records.append(contentsOf: try output.records.compactMap(decodeStarRecord))
      cursor = output.cursor
      if let cursor, !seenCursors.insert(cursor).inserted {
        throw TangledError.transport("PDS returned a repeated pagination cursor")
      }
    } while cursor != nil

    return records
  }

  private func decodeStarRecord(
    _ record: Com.Atproto.RepoListRecords_Record
  ) throws -> TangledRecord<Star>? {
    guard case .record(let value) = record.value,
      let star = value as? Sh.Tangled.FeedStar
    else {
      return nil
    }

    let subject: StarSubject
    switch star.subject {
    case .feedStarRepo(let repository):
      subject = .repository(did: repository.did.rawValue)
    case .feedStarString(let string):
      subject = .string(uri: string.uri.rawValue)
    case ._other:
      return nil
    }
    return TangledRecord(
      uri: record.uri.rawValue,
      cid: record.cid.rawValue,
      value: Star(subject: subject, createdAt: star.createdAt)
    )
  }

  package func perform<Value: Sendable>(
    _ operation: () async throws -> Value
  ) async throws -> Value {
    do {
      return try await operation()
    } catch let error as TangledError {
      throw error
    } catch let error as URLError {
      throw TangledError.network(error)
    } catch let error as OAuthScopeError {
      throw TangledError.insufficientScope(String(describing: error))
    } catch let error as DecodingError {
      throw TangledError.decoding(error)
    } catch OAuth.Errors.oauthError(let response, _)
      where response.error == "InvalidSwap"
    {
      throw TangledError.conflict(nil)
    } catch Com.Atproto.RepoPutRecord.Error.invalidswap(let message) {
      throw TangledError.conflict(message)
    } catch Com.Atproto.RepoApplyWrites.Error.invalidswap(let message) {
      throw TangledError.conflict(message)
    } catch Com.Atproto.RepoDeleteRecord.Error.invalidswap(let message) {
      throw TangledError.conflict(message)
    } catch let error as any XRPCError {
      throw error
    } catch {
      throw TangledError.transport(String(describing: error))
    }
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

private final class SessionStoreBox: @unchecked Sendable {
  let value: any SessionStore

  init(_ value: any SessionStore) {
    self.value = value
  }
}

private enum PDSClientError: Error, Sendable {
  case invalidRecordURI(String)
  case invalidApplyWritesResult
  case invalidPullRequestRecord
}
