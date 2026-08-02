import Foundation
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
  public func diff(repositoryURI: String, ref: String) async throws -> GitCommitDiff {
    try validateGitRepositoryURI(repositoryURI)
    try requireNonempty(ref, name: "git ref")
    let data = try await generatedQuery { try await RepoDiff(ref: ref, repo: repositoryURI) }
    return try decodeGitResponse(WireGitCommitDiff.self, from: data).model
  }

  public func compare(
    repositoryURI: String,
    baseRevision: String,
    headRevision: String
  ) async throws -> GitComparison {
    try validateGitRepositoryURI(repositoryURI)
    try requireNonempty(baseRevision, name: "base revision")
    try requireNonempty(headRevision, name: "head revision")
    let data = try await generatedQuery {
      try await RepoCompare(repo: repositoryURI, rev1: baseRevision, rev2: headRevision)
    }
    return try decodeGitComparison(from: data)
  }
}

func decodeGitComparison(from data: Data) throws(TangledError) -> GitComparison {
  do {
    return try JSONDecoder().decode(WireGitComparison.self, from: data).model
  } catch {
    throw TangledError.decoding(error)
  }
}

private extension BobbinClient {
  func decodeGitResponse<Value: Decodable>(
    _ type: Value.Type,
    from data: Data
  ) throws(TangledError) -> Value {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw TangledError.decoding(error)
    }
  }
}

private struct WireGitCommitDiff: Decodable {
  let ref: String
  let diff: WireNiceDiff

  var model: GitCommitDiff {
    GitCommitDiff(
      ref: ref,
      commit: diff.commit.model,
      stat: diff.stat.model,
      files: diff.diff.map(\.model)
    )
  }
}

private struct WireNiceDiff: Decodable {
  let commit: WireDiffCommit
  let stat: WireDiffStat
  let diff: [WireNiceDiffFile]
}

private struct WireDiffCommit: Decodable {
  let hash: [UInt8]
  let author: WireDiffSignature
  let committer: WireDiffSignature
  let message: String
  let tree: String
  let parentHashes: [[UInt8]]?
  let changeID: String?

  enum CodingKeys: String, CodingKey {
    case hash, author, committer, message, tree
    case parentHashes = "parent_hashes"
    case changeID = "change_id"
  }

  var model: GitCommit {
    GitCommit(
      hash: hash.hexString,
      author: author.model,
      committer: committer.model,
      message: message,
      tree: tree,
      parentHashes: (parentHashes ?? []).map(\.hexString),
      changeID: changeID
    )
  }
}

private struct WireDiffSignature: Decodable {
  let name: String
  let email: String
  let when: FormatString<Date>

  enum CodingKeys: String, CodingKey {
    case name = "Name"
    case email = "Email"
    case when = "When"
  }

  var model: GitSignature { GitSignature(name: name, email: email, when: when) }
}

private struct WireDiffStat: Decodable {
  let insertions: Int
  let deletions: Int
  let filesChanged: Int

  enum CodingKeys: String, CodingKey {
    case insertions, deletions
    case filesChanged = "files_changed"
  }

  var model: GitDiffStat {
    GitDiffStat(insertions: insertions, deletions: deletions, filesChanged: filesChanged)
  }
}

private struct WireNiceDiffFile: Decodable {
  let name: WireDiffName
  let textFragments: [WireNiceDiffFragment]?
  let isBinary: Bool
  let isNew: Bool
  let isDelete: Bool
  let isCopy: Bool
  let isRename: Bool

  enum CodingKeys: String, CodingKey {
    case name
    case textFragments = "text_fragments"
    case isBinary = "is_binary"
    case isNew = "is_new"
    case isDelete = "is_delete"
    case isCopy = "is_copy"
    case isRename = "is_rename"
  }

  var model: GitDiffFile {
    GitDiffFile(
      oldName: name.old,
      newName: name.new,
      textFragments: (textFragments ?? []).map(\.model),
      isBinary: isBinary,
      isNew: isNew,
      isDelete: isDelete,
      isCopy: isCopy,
      isRename: isRename
    )
  }
}

private struct WireDiffName: Decodable {
  let old: String
  let new: String
}

private struct WireNiceDiffFragment: Decodable {
  let comment: String
  let oldPosition: Int
  let oldLines: Int
  let newPosition: Int
  let newLines: Int
  let linesAdded: Int
  let linesDeleted: Int
  let leadingContext: Int
  let trailingContext: Int
  let lines: [WireNiceDiffLine]

  enum CodingKeys: String, CodingKey {
    case comment = "Comment"
    case oldPosition = "OldPosition"
    case oldLines = "OldLines"
    case newPosition = "NewPosition"
    case newLines = "NewLines"
    case linesAdded = "LinesAdded"
    case linesDeleted = "LinesDeleted"
    case leadingContext = "LeadingContext"
    case trailingContext = "TrailingContext"
    case lines = "Lines"
  }

  var model: GitDiffFragment {
    GitDiffFragment(
      comment: comment,
      oldPosition: oldPosition,
      oldLines: oldLines,
      newPosition: newPosition,
      newLines: newLines,
      linesAdded: linesAdded,
      linesDeleted: linesDeleted,
      leadingContext: leadingContext,
      trailingContext: trailingContext,
      lines: lines.map(\.model)
    )
  }
}

private struct WireNiceDiffLine: Decodable {
  let operation: Int
  let content: String

  enum CodingKeys: String, CodingKey {
    case operation = "Op"
    case content = "Line"
  }

  var model: GitDiffLine {
    GitDiffLine(operation: GitDiffLineOperation(rawValue: operation), content: content)
  }
}

private struct WireGitComparison: Decodable {
  let rev1: String
  let rev2: String
  let formatPatch: [WireFormatPatch]?
  let patch: String?
  let combinedPatch: [WireCompareDiffFile]?
  let combinedPatchRaw: String?

  enum CodingKeys: String, CodingKey {
    case rev1, rev2, patch
    case formatPatch = "format_patch"
    case combinedPatch = "combined_patch"
    case combinedPatchRaw = "combined_patch_raw"
  }

  var model: GitComparison {
    GitComparison(
      baseRevision: rev1,
      headRevision: rev2,
      formatPatches: (formatPatch ?? []).map(\.model),
      patch: patch ?? "",
      combinedFiles: (combinedPatch ?? []).map(\.model),
      combinedPatch: combinedPatchRaw ?? ""
    )
  }
}

private struct WireFormatPatch: Decodable {
  let files: [WireCompareDiffFile]
  let sha: String
  let author: WirePatchIdentity
  let authorDate: FormatString<Date>
  let committer: WirePatchIdentity?
  let committerDate: FormatString<Date>?
  let title: String
  let body: String
  let subjectPrefix: String
  let bodyAppendix: String
  let rawHeaders: [String: [String]]
  let raw: String

  enum CodingKeys: String, CodingKey {
    case files = "Files"
    case sha = "SHA"
    case author = "Author"
    case authorDate = "AuthorDate"
    case committer = "Committer"
    case committerDate = "CommitterDate"
    case title = "Title"
    case body = "Body"
    case subjectPrefix = "SubjectPrefix"
    case bodyAppendix = "BodyAppendix"
    case rawHeaders = "RawHeaders"
    case raw = "Raw"
  }

  var model: GitFormatPatch {
    GitFormatPatch(
      files: files.map(\.model),
      sha: sha,
      author: author.signature(when: authorDate),
      committer: committer.flatMap { identity in
        committerDate.map { identity.signature(when: $0) }
      },
      title: title,
      body: body,
      subjectPrefix: subjectPrefix,
      bodyAppendix: bodyAppendix,
      headers: rawHeaders,
      raw: raw
    )
  }
}

private struct WirePatchIdentity: Decodable {
  let name: String
  let email: String

  enum CodingKeys: String, CodingKey {
    case name = "Name"
    case email = "Email"
  }

  func signature(when: FormatString<Date>) -> GitSignature {
    GitSignature(name: name, email: email, when: when)
  }
}

private struct WireCompareDiffFile: Decodable {
  let oldName: String
  let newName: String
  let isNew: Bool
  let isDelete: Bool
  let isCopy: Bool
  let isRename: Bool
  let oldMode: Int
  let newMode: Int
  let oldOIDPrefix: String
  let newOIDPrefix: String
  let score: Int
  let textFragments: [WireNiceDiffFragment]?
  let isBinary: Bool

  enum CodingKeys: String, CodingKey {
    case oldName = "OldName"
    case newName = "NewName"
    case isNew = "IsNew"
    case isDelete = "IsDelete"
    case isCopy = "IsCopy"
    case isRename = "IsRename"
    case oldMode = "OldMode"
    case newMode = "NewMode"
    case oldOIDPrefix = "OldOIDPrefix"
    case newOIDPrefix = "NewOIDPrefix"
    case score = "Score"
    case textFragments = "TextFragments"
    case isBinary = "IsBinary"
  }

  var model: GitDiffFile {
    GitDiffFile(
      oldName: oldName,
      newName: newName,
      textFragments: (textFragments ?? []).map(\.model),
      isBinary: isBinary,
      isNew: isNew,
      isDelete: isDelete,
      isCopy: isCopy,
      isRename: isRename,
      oldMode: oldMode,
      newMode: newMode,
      oldObjectIDPrefix: oldOIDPrefix,
      newObjectIDPrefix: newOIDPrefix,
      score: score
    )
  }
}

private extension [UInt8] {
  var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
