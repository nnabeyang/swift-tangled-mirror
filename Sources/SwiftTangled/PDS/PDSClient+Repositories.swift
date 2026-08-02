import Foundation
import SwiftAtproto
import TangledLexicons

extension PDSClient {
  package func requireRepositoryRecordCreateScope() throws {
    try requireRepositoryRecordScope(action: .create)
  }

  package func requireRepositoryRecordDeleteScope() throws {
    try requireRepositoryRecordScope(action: .delete)
  }

  public func createRepositoryRecord(
    rkey: String,
    name: String,
    knot: String,
    source: String?,
    repositoryDID: String
  ) async throws -> TangledRecord<Repository> {
    try requireRepositoryRecordCreateScope()
    let recordKey: RecordKey
    do {
      recordKey = try RecordKey(string: rkey)
    } catch {
      throw TangledError.invalidRequest("invalid repository record key: \(rkey)")
    }
    let parsedRepositoryDID: DID
    do {
      parsedRepositoryDID = try DID(string: repositoryDID)
    } catch {
      throw TangledError.invalidRequest("invalid repository DID: \(repositoryDID)")
    }
    let parsedSource: FormatString<URI>? = try source.map { value in
      do {
        return FormatString(try URI(string: value))
      } catch {
        throw TangledError.invalidRequest("invalid repository source URL: \(value)")
      }
    }
    let createdAt = FormatString(now())
    let value = Sh.Tangled.Repo(
      createdAt: createdAt,
      knot: knot,
      name: name,
      repoDid: FormatString(parsedRepositoryDID),
      source: parsedSource
    )
    let output = try await perform {
      try await client.RepoCreateRecord(
        input: Com.Atproto.RepoCreateRecord_Input(
          collection: FormatString(rawValue: Sh.Tangled.Repo.nsId),
          record: .record(value),
          repo: FormatString(rawValue: repoDID),
          rkey: FormatString(recordKey),
          validate: nil
        )
      )
    }
    return TangledRecord(
      uri: output.uri.rawValue,
      cid: output.cid.rawValue,
      value: Repository(
        name: name,
        knot: knot,
        source: source,
        repoDID: repositoryDID,
        createdAt: createdAt
      )
    )
  }

  public func deleteRepositoryRecord(
    _ current: TangledRecord<Repository>
  ) async throws {
    try requireRepositoryRecordDeleteScope()
    guard let uri = FormatString<ATURI>(rawValue: current.uri).typed,
      uri.authority.rawValue == repoDID,
      uri.collection?.rawValue == Sh.Tangled.Repo.nsId,
      let rkey = uri.rkey,
      let cid = current.cid,
      !cid.isEmpty
    else {
      throw TangledError.invalidRequest(
        "repository record must be owned by the session and expose a CID and rkey"
      )
    }
    _ = try await perform {
      try await client.RepoDeleteRecord(
        input: Com.Atproto.RepoDeleteRecord_Input(
          collection: FormatString(rawValue: Sh.Tangled.Repo.nsId),
          repo: FormatString(rawValue: repoDID),
          rkey: FormatString(rkey),
          swapRecord: FormatString(rawValue: cid)
        )
      )
    }
  }

  private func requireRepositoryRecordScope(
    action: LexPermissionAction
  ) throws(TangledError) {
    guard grantedScopes.allowsRepo(collection: Sh.Tangled.Repo.nsId, action: action) else {
      throw TangledError.insufficientScope("repo:\(Sh.Tangled.Repo.nsId)")
    }
  }
}
