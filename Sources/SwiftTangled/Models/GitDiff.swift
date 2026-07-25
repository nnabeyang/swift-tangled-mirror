import Foundation

public struct GitDiffLineOperation:
  RawRepresentable, Codable, Equatable, Hashable, Sendable
{
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let context = GitDiffLineOperation(rawValue: 0)
  public static let deletion = GitDiffLineOperation(rawValue: 1)
  public static let addition = GitDiffLineOperation(rawValue: 2)

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try Int(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try rawValue.encode(to: encoder)
  }
}

public struct GitDiffLine: Codable, Equatable, Hashable, Sendable {
  public let operation: GitDiffLineOperation
  public let content: String

  public init(operation: GitDiffLineOperation, content: String) {
    self.operation = operation
    self.content = content
  }
}

public struct GitDiffFragment: Codable, Equatable, Hashable, Sendable {
  public let comment: String
  public let oldPosition: Int
  public let oldLines: Int
  public let newPosition: Int
  public let newLines: Int
  public let linesAdded: Int
  public let linesDeleted: Int
  public let leadingContext: Int
  public let trailingContext: Int
  public let lines: [GitDiffLine]

  public init(
    comment: String,
    oldPosition: Int,
    oldLines: Int,
    newPosition: Int,
    newLines: Int,
    linesAdded: Int,
    linesDeleted: Int,
    leadingContext: Int,
    trailingContext: Int,
    lines: [GitDiffLine]
  ) {
    self.comment = comment
    self.oldPosition = oldPosition
    self.oldLines = oldLines
    self.newPosition = newPosition
    self.newLines = newLines
    self.linesAdded = linesAdded
    self.linesDeleted = linesDeleted
    self.leadingContext = leadingContext
    self.trailingContext = trailingContext
    self.lines = lines
  }
}

public struct GitDiffFile: Codable, Equatable, Hashable, Sendable {
  public let oldName: String
  public let newName: String
  public let textFragments: [GitDiffFragment]
  public let isBinary: Bool
  public let isNew: Bool
  public let isDelete: Bool
  public let isCopy: Bool
  public let isRename: Bool
  public let oldMode: Int?
  public let newMode: Int?
  public let oldObjectIDPrefix: String?
  public let newObjectIDPrefix: String?
  public let score: Int?

  public init(
    oldName: String,
    newName: String,
    textFragments: [GitDiffFragment] = [],
    isBinary: Bool = false,
    isNew: Bool = false,
    isDelete: Bool = false,
    isCopy: Bool = false,
    isRename: Bool = false,
    oldMode: Int? = nil,
    newMode: Int? = nil,
    oldObjectIDPrefix: String? = nil,
    newObjectIDPrefix: String? = nil,
    score: Int? = nil
  ) {
    self.oldName = oldName
    self.newName = newName
    self.textFragments = textFragments
    self.isBinary = isBinary
    self.isNew = isNew
    self.isDelete = isDelete
    self.isCopy = isCopy
    self.isRename = isRename
    self.oldMode = oldMode
    self.newMode = newMode
    self.oldObjectIDPrefix = oldObjectIDPrefix
    self.newObjectIDPrefix = newObjectIDPrefix
    self.score = score
  }

  public var path: String { isDelete ? oldName : newName }
}

public struct GitDiffStat: Codable, Equatable, Hashable, Sendable {
  public let insertions: Int
  public let deletions: Int
  public let filesChanged: Int

  public init(insertions: Int, deletions: Int, filesChanged: Int) {
    self.insertions = insertions
    self.deletions = deletions
    self.filesChanged = filesChanged
  }
}

public struct GitCommitDiff: Codable, Equatable, Hashable, Sendable {
  public let ref: String
  public let commit: GitCommit
  public let stat: GitDiffStat
  public let files: [GitDiffFile]

  public init(ref: String, commit: GitCommit, stat: GitDiffStat, files: [GitDiffFile]) {
    self.ref = ref
    self.commit = commit
    self.stat = stat
    self.files = files
  }
}

public struct GitFormatPatch: Codable, Equatable, Hashable, Sendable {
  public let files: [GitDiffFile]
  public let sha: String
  public let author: GitSignature
  public let committer: GitSignature?
  public let title: String
  public let body: String
  public let subjectPrefix: String
  public let bodyAppendix: String
  public let headers: [String: [String]]
  public let raw: String

  public init(
    files: [GitDiffFile],
    sha: String,
    author: GitSignature,
    committer: GitSignature? = nil,
    title: String,
    body: String,
    subjectPrefix: String,
    bodyAppendix: String,
    headers: [String: [String]],
    raw: String
  ) {
    self.files = files
    self.sha = sha
    self.author = author
    self.committer = committer
    self.title = title
    self.body = body
    self.subjectPrefix = subjectPrefix
    self.bodyAppendix = bodyAppendix
    self.headers = headers
    self.raw = raw
  }
}

public struct GitComparison: Codable, Equatable, Hashable, Sendable {
  public let baseRevision: String
  public let headRevision: String
  public let formatPatches: [GitFormatPatch]
  public let patch: String
  public let combinedFiles: [GitDiffFile]
  public let combinedPatch: String

  public init(
    baseRevision: String,
    headRevision: String,
    formatPatches: [GitFormatPatch],
    patch: String,
    combinedFiles: [GitDiffFile],
    combinedPatch: String
  ) {
    self.baseRevision = baseRevision
    self.headRevision = headRevision
    self.formatPatches = formatPatches
    self.patch = patch
    self.combinedFiles = combinedFiles
    self.combinedPatch = combinedPatch
  }
}
