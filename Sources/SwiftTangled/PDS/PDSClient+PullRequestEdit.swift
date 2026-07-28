import Foundation
import SwiftAtproto
import TangledLexicons

extension PDSClient {
  package func updatePullRequest(
    current: PullRequestRecordSnapshot,
    title: String,
    body: String?
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
      throw TangledError.invalidRequest("only the Pull Request owner can edit it")
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
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      throw TangledError.invalidRequest("pull request title must not be empty")
    }
    let body = normalizedPullRequestBody(body)
    try requirePullScope()

    let rawRecord = try replacingPullRequestMetadata(
      in: current.rawValue,
      title: title,
      body: body
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

  private func replacingPullRequestMetadata(
    in raw: UnknownATPValue,
    title: String,
    body: String?
  ) throws -> UnknownATPValue {
    let encoded = try JSONEncoder().encode(raw)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
      throw TangledError.decoding(PDSClientError.invalidPullRequestRecord)
    }
    object["title"] = title
    if let body {
      object["body"] = body
    } else {
      object.removeValue(forKey: "body")
    }
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.userInfo[.atprotoLexiconDecodingMode] = LexiconDecodingMode.permissive
    return try decoder.decode(UnknownATPValue.self, from: data)
  }

  private func normalizedPullRequestBody(_ body: String?) -> String? {
    guard let value = body?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else {
      return nil
    }
    return value
  }
}
