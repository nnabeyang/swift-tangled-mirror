import Foundation
import SwiftAtproto

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct GitSignature: Codable, Equatable, Hashable, Sendable {
  public let name: String
  public let email: String
  public let when: FormatString<Date>

  public init(name: String, email: String, when: FormatString<Date>) {
    self.name = name
    self.email = email
    self.when = when
  }
}

public struct GitCommit: Codable, Equatable, Hashable, Sendable {
  public let hash: String
  public let author: GitSignature
  public let committer: GitSignature
  public let message: String
  public let tree: String
  public let parentHashes: [String]
  public let changeID: String?

  public init(
    hash: String,
    author: GitSignature,
    committer: GitSignature,
    message: String,
    tree: String,
    parentHashes: [String] = [],
    changeID: String? = nil
  ) {
    self.hash = hash
    self.author = author
    self.committer = committer
    self.message = message
    self.tree = tree
    self.parentHashes = parentHashes
    self.changeID = changeID
  }
}

public struct GitReference: Codable, Equatable, Hashable, Sendable {
  public let name: String
  public let hash: String

  public init(name: String, hash: String) {
    self.name = name
    self.hash = hash
  }
}

public struct GitBranch: Codable, Equatable, Hashable, Sendable {
  public let reference: GitReference
  public let commit: GitCommit?
  public let isDefault: Bool

  public init(
    reference: GitReference,
    commit: GitCommit? = nil,
    isDefault: Bool = false
  ) {
    self.reference = reference
    self.commit = commit
    self.isDefault = isDefault
  }
}

public struct GitTag: Codable, Equatable, Hashable, Sendable {
  public let reference: GitReference
  public let tagger: GitSignature?
  public let message: String?
  public let targetHash: String?

  public init(
    reference: GitReference,
    tagger: GitSignature? = nil,
    message: String? = nil,
    targetHash: String? = nil
  ) {
    self.reference = reference
    self.tagger = tagger
    self.message = message
    self.targetHash = targetHash
  }
}

public struct GitRepositoryDescription: Codable, Equatable, Hashable, Sendable {
  public let ownerDID: String
  public let repositoryDID: String
  public let rkey: String

  public init(ownerDID: String, repositoryDID: String, rkey: String) {
    self.ownerDID = ownerDID
    self.repositoryDID = repositoryDID
    self.rkey = rkey
  }
}

public struct GitLanguage: Codable, Equatable, Hashable, Sendable {
  public let name: String
  public let size: Int
  public let percentage: Int
  public let fileCount: Int?
  public let color: String?
  public let extensions: [String]?

  public init(
    name: String,
    size: Int,
    percentage: Int,
    fileCount: Int? = nil,
    color: String? = nil,
    extensions: [String]? = nil
  ) {
    self.name = name
    self.size = size
    self.percentage = percentage
    self.fileCount = fileCount
    self.color = color
    self.extensions = extensions
  }
}

public struct GitLanguageReport: Codable, Equatable, Hashable, Sendable {
  public let ref: String
  public let languages: [GitLanguage]
  public let totalFiles: Int?
  public let totalSize: Int?

  public init(
    ref: String,
    languages: [GitLanguage],
    totalFiles: Int? = nil,
    totalSize: Int? = nil
  ) {
    self.ref = ref
    self.languages = languages
    self.totalFiles = totalFiles
    self.totalSize = totalSize
  }
}

public enum GitArchiveFormat: String, Codable, Equatable, Hashable, Sendable {
  case tar
  case zip
  case tarGzip = "tar.gz"
  case tarBzip2 = "tar.bz2"
  case tarXz = "tar.xz"
}

public enum GitArchiveByteRange: Equatable, Hashable, Sendable {
  case bytes(ClosedRange<Int>)
  case from(Int)
  case suffix(Int)
}

public struct GitArchive: Codable, Equatable, Hashable, Sendable {
  public let content: Data
  public let statusCode: Int
  public let contentType: String?
  public let contentLength: Int?
  public let contentRange: String?
  public let contentDisposition: String?
  public let acceptRanges: String?

  public init(
    content: Data,
    statusCode: Int,
    contentType: String? = nil,
    contentLength: Int? = nil,
    contentRange: String? = nil,
    contentDisposition: String? = nil,
    acceptRanges: String? = nil
  ) {
    self.content = content
    self.statusCode = statusCode
    self.contentType = contentType
    self.contentLength = contentLength
    self.contentRange = contentRange
    self.contentDisposition = contentDisposition
    self.acceptRanges = acceptRanges
  }

  public var isPartial: Bool {
    statusCode == 206
  }
}

public struct GitArchiveStream: AsyncSequence, Sendable {
  public typealias Element = Data
  public typealias Failure = any Error

  public let statusCode: Int
  public let contentType: String?
  public let contentLength: Int?
  public let contentRange: String?
  public let contentDisposition: String?
  public let acceptRanges: String?

  private let body: HTTPBodyStream

  init(
    body: HTTPBodyStream,
    statusCode: Int,
    contentType: String? = nil,
    contentLength: Int? = nil,
    contentRange: String? = nil,
    contentDisposition: String? = nil,
    acceptRanges: String? = nil
  ) {
    self.body = body
    self.statusCode = statusCode
    self.contentType = contentType
    self.contentLength = contentLength
    self.contentRange = contentRange
    self.contentDisposition = contentDisposition
    self.acceptRanges = acceptRanges
  }

  public var isPartial: Bool {
    statusCode == 206
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(body: body, iterator: body.makeAsyncIterator())
  }

  public func cancel() {
    body.cancel()
  }

  @discardableResult
  public func write(to destinationURL: URL) async throws -> Int64 {
    let fileManager = FileManager.default
    let directory = destinationURL.deletingLastPathComponent()
    let temporaryURL = directory.appendingPathComponent(
      ".\(destinationURL.lastPathComponent).\(UUID().uuidString).download"
    )
    guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
      throw TangledError.transport("Unable to create temporary archive file")
    }

    var completed = false
    defer {
      if !completed {
        try? fileManager.removeItem(at: temporaryURL)
      }
    }

    let file = try FileHandle(forWritingTo: temporaryURL)
    defer { try? file.close() }

    var written: Int64 = 0
    do {
      for try await chunk in self {
        try file.write(contentsOf: chunk)
        written += Int64(chunk.count)
      }
      try file.synchronize()
      try file.close()

      guard systemRename(temporaryURL.path, destinationURL.path) == 0 else {
        throw TangledError.transport(
          "Unable to replace archive file: \(String(cString: strerror(errno)))"
        )
      }
      completed = true
      return written
    } catch {
      cancel()
      throw error
    }
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    public typealias Element = Data
    public typealias Failure = any Error

    fileprivate let body: HTTPBodyStream
    fileprivate var iterator: HTTPBodyStream.AsyncIterator

    public mutating func next() async throws -> Data? {
      do {
        return try await iterator.next()
      } catch is CancellationError {
        body.cancel()
        throw CancellationError()
      } catch let error as TangledError {
        body.cancel()
        throw error
      } catch let error as URLError {
        body.cancel()
        if Task.isCancelled || error.code == .cancelled {
          throw CancellationError()
        }
        throw TangledError.network(error)
      } catch {
        body.cancel()
        throw TangledError.transport(String(describing: error))
      }
    }
  }
}

private func systemRename(_ source: String, _ destination: String) -> Int32 {
  #if canImport(Darwin)
    Darwin.rename(source, destination)
  #elseif canImport(Glibc)
    Glibc.rename(source, destination)
  #else
    -1
  #endif
}

public struct GitDefaultBranch: Codable, Equatable, Hashable, Sendable {
  public let name: String
  public let hash: String
  public let shortHash: String?
  public let when: FormatString<Date>
  public let message: String?
  public let author: GitSignature?

  public init(
    name: String,
    hash: String,
    shortHash: String? = nil,
    when: FormatString<Date>,
    message: String? = nil,
    author: GitSignature? = nil
  ) {
    self.name = name
    self.hash = hash
    self.shortHash = shortHash
    self.when = when
    self.message = message
    self.author = author
  }
}

public struct GitLastCommit: Codable, Equatable, Hashable, Sendable {
  public let hash: String
  public let message: String
  public let when: FormatString<Date>
  public let author: GitSignature?

  public init(
    hash: String,
    message: String,
    when: FormatString<Date>,
    author: GitSignature? = nil
  ) {
    self.hash = hash
    self.message = message
    self.when = when
    self.author = author
  }
}

public struct GitTreeEntry: Codable, Equatable, Hashable, Sendable {
  public let name: String
  public let mode: String
  public let size: Int
  public let lastCommit: GitLastCommit?

  public init(
    name: String,
    mode: String,
    size: Int,
    lastCommit: GitLastCommit? = nil
  ) {
    self.name = name
    self.mode = mode
    self.size = size
    self.lastCommit = lastCommit
  }

  public var isDirectory: Bool { mode == "0040000" || mode == "040000" }
}

public struct GitTreeReadme: Codable, Equatable, Hashable, Sendable {
  public let filename: String
  public let contents: String

  public init(filename: String, contents: String) {
    self.filename = filename
    self.contents = contents
  }
}

public struct GitTree: Codable, Equatable, Hashable, Sendable {
  public let ref: String
  public let parent: String?
  public let parentPath: String?
  public let readme: GitTreeReadme?
  public let lastCommit: GitLastCommit?
  public let entries: [GitTreeEntry]

  public init(
    ref: String,
    parent: String? = nil,
    parentPath: String? = nil,
    readme: GitTreeReadme? = nil,
    lastCommit: GitLastCommit? = nil,
    entries: [GitTreeEntry]
  ) {
    self.ref = ref
    self.parent = parent
    self.parentPath = parentPath
    self.readme = readme
    self.lastCommit = lastCommit
    self.entries = entries
  }
}

public struct GitLogPage: Codable, Equatable, Hashable, Sendable {
  public let commits: [GitCommit]
  public let cursor: String?
  public let ref: String
  public let total: Int
  public let page: Int

  public init(
    commits: [GitCommit],
    cursor: String?,
    ref: String,
    total: Int,
    page: Int
  ) {
    self.commits = commits
    self.cursor = cursor
    self.ref = ref
    self.total = total
    self.page = page
  }
}

public struct GitBlobEncoding:
  RawRepresentable, Codable, Equatable, Hashable, Sendable
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let utf8 = GitBlobEncoding(rawValue: "utf-8")
  public static let base64 = GitBlobEncoding(rawValue: "base64")

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try String(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try rawValue.encode(to: encoder)
  }
}

public struct GitSubmodule: Codable, Equatable, Hashable, Sendable {
  public let name: String
  public let url: String
  public let branch: String?

  public init(name: String, url: String, branch: String? = nil) {
    self.name = name
    self.url = url
    self.branch = branch
  }
}

public struct GitBlob: Codable, Equatable, Hashable, Sendable {
  public let ref: String
  public let path: String
  public let content: Data?
  public let encoding: GitBlobEncoding?
  public let size: Int?
  public let isBinary: Bool
  public let mimeType: String?
  public let submodule: GitSubmodule?
  public let lastCommit: GitLastCommit?
  public let fileTooLarge: Bool

  public init(
    ref: String,
    path: String,
    content: Data? = nil,
    encoding: GitBlobEncoding? = nil,
    size: Int? = nil,
    isBinary: Bool = false,
    mimeType: String? = nil,
    submodule: GitSubmodule? = nil,
    lastCommit: GitLastCommit? = nil,
    fileTooLarge: Bool = false
  ) {
    self.ref = ref
    self.path = path
    self.content = content
    self.encoding = encoding
    self.size = size
    self.isBinary = isBinary
    self.mimeType = mimeType
    self.submodule = submodule
    self.lastCommit = lastCommit
    self.fileTooLarge = fileTooLarge
  }
}
