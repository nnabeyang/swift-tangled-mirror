import ArgumentParser
import Foundation
import SwiftTangled

struct RepoCommandDependencies: Sendable {
  let resolveRepository: @Sendable (String) async throws -> TangledRecord<Repository>
  let resolveOwnerDID: @Sendable (String) async throws -> String
  let repositories:
    @Sendable (String, String?, Int, BobbinSortOrder) async throws -> Page<
      TangledRecord<Repository>
    >
  let sessionDID: @Sendable () throws -> String?
  let originURL: @Sendable () throws -> String
  let defaultBranch: @Sendable (String) async throws -> GitDefaultBranch
  let tree: @Sendable (String, String, String?) async throws -> GitTree
  let log: @Sendable (String, String, String?, String?, Int) async throws -> GitLogPage
  let blob: @Sendable (String, String, String) async throws -> GitBlob
  let languages: @Sendable (String, String) async throws -> GitLanguageReport
  let branches: @Sendable (String, String?, Int) async throws -> Page<GitBranch>
  let tags: @Sendable (String, String?, Int) async throws -> Page<GitTag>
  let archive: @Sendable (String, String, GitArchiveFormat, String?, URL) async throws -> Int64
  let star: @Sendable (String) async throws -> TangledRecord<Star>
  let unstar: @Sendable (String) async throws -> Bool

  static let live: RepoCommandDependencies = {
    let client = BobbinClient()
    let locator = RepositoryLocator(client: client)
    let pdsRecordClient = PDSRecordClient()
    return RepoCommandDependencies(
      resolveRepository: { try await locator.resolve($0) },
      resolveOwnerDID: { try await locator.resolveOwnerDID($0) },
      repositories: { ownerDID, cursor, limit, order in
        try await authoritativeRepositories(
          client: pdsRecordClient,
          ownerDID: ownerDID,
          cursor: cursor,
          limit: limit,
          order: order
        )
      },
      sessionDID: { try CLISessionStore.make().store.load()?.did },
      originURL: { try GitOriginReader().read() },
      defaultBranch: { try await client.defaultBranch(repositoryURI: $0) },
      tree: { repositoryURI, ref, path in
        try await client.tree(repositoryURI: repositoryURI, ref: ref, path: path)
      },
      log: { repositoryURI, ref, path, cursor, limit in
        try await client.log(
          repositoryURI: repositoryURI,
          ref: ref,
          path: path,
          cursor: cursor,
          limit: limit
        )
      },
      blob: { repositoryURI, ref, path in
        try await client.blob(repositoryURI: repositoryURI, ref: ref, path: path)
      },
      languages: { repositoryURI, ref in
        try await client.languages(repositoryURI: repositoryURI, ref: ref)
      },
      branches: { repositoryURI, cursor, limit in
        try await client.branches(
          repositoryURI: repositoryURI,
          cursor: cursor,
          limit: limit
        )
      },
      tags: { repositoryURI, cursor, limit in
        try await client.tags(
          repositoryURI: repositoryURI,
          cursor: cursor,
          limit: limit
        )
      },
      archive: { repositoryURI, ref, format, prefix, destination in
        let stream = try await client.archiveStream(
          repositoryURI: repositoryURI,
          ref: ref,
          format: format,
          prefix: prefix
        )
        return try await stream.write(to: destination)
      },
      star: { repositoryDID in
        let client = try PDSClient.restore(from: CLISessionStore.make().store)
        return try await client.star(repositoryDID: repositoryDID)
      },
      unstar: { repositoryDID in
        let client = try PDSClient.restore(from: CLISessionStore.make().store)
        return try await client.unstar(repositoryDID: repositoryDID)
      }
    )
  }()
}

private func authoritativeRepositories(
  client: PDSRecordClient,
  ownerDID: String,
  cursor: String?,
  limit: Int,
  order: BobbinSortOrder
) async throws -> Page<TangledRecord<Repository>> {
  var items: [TangledRecord<Repository>] = []
  var nextCursor = cursor
  var seenCursors = Set<String>()

  repeat {
    let page = try await client.repositories(
      ownerDID: ownerDID,
      cursor: nextCursor,
      limit: min(limit - items.count, 100),
      reverse: order == .descending
    )
    items.append(contentsOf: page.items)
    guard items.count < limit, let next = page.cursor else {
      return Page(items: items, cursor: page.cursor)
    }
    guard seenCursors.insert(next).inserted else {
      throw TangledError.upstreamFailed("repository records returned a repeated cursor")
    }
    nextCursor = next
  } while items.count < limit

  return Page(items: items, cursor: nextCursor)
}

struct RepoCommandService: Sendable {
  private let dependencies: RepoCommandDependencies
  private let formatter: CLIFormatter

  init(
    dependencies: RepoCommandDependencies = .live,
    formatter: CLIFormatter = .plain
  ) {
    self.dependencies = dependencies
    self.formatter = formatter
  }

  func view(repository: String?, json: Bool) async throws -> CLICommandOutput {
    let reference = try repository ?? dependencies.originURL()
    let record = try await dependencies.resolveRepository(reference)
    return CLICommandOutput(
      stdout: try json ? formatter.json(record) : format(record)
    )
  }

  func list(
    owner: String?,
    limit: Int,
    cursor: String?,
    sort: BobbinSortOrder = .descending,
    json: Bool
  ) async throws -> CLICommandOutput {
    let ownerDID: String
    if let owner {
      ownerDID = try await dependencies.resolveOwnerDID(owner)
    } else if let sessionDID = try dependencies.sessionDID() {
      ownerDID = sessionDID
    } else {
      throw CLICommandError.authenticationRequired(
        "run 'tng auth login <handle>' or pass an owner DID/handle"
      )
    }

    let page = try await dependencies.repositories(ownerDID, cursor, limit, sort)
    return CLICommandOutput(
      stdout: try json ? formatter.json(page) : format(page.items),
      stderr: formatter.cursorDiagnostic(page.cursor, json: json)
    )
  }

  func tree(
    repository: String?,
    ref: String?,
    path: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let target = try await gitTarget(repository: repository, ref: ref)
    let tree = try await dependencies.tree(target.repositoryURI, target.ref, path)
    return CLICommandOutput(stdout: try json ? formatter.json(tree) : format(tree))
  }

  func log(
    repository: String?,
    ref: String?,
    path: String?,
    cursor: String?,
    limit: Int,
    json: Bool
  ) async throws -> CLICommandOutput {
    let target = try await gitTarget(repository: repository, ref: ref)
    let page = try await dependencies.log(
      target.repositoryURI,
      target.ref,
      path,
      cursor,
      limit
    )
    return CLICommandOutput(
      stdout: try json ? formatter.json(page) : format(page.commits),
      stderr: formatter.cursorDiagnostic(page.cursor, json: json)
    )
  }

  func blob(
    path: String,
    repository: String?,
    ref: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let target = try await gitTarget(repository: repository, ref: ref)
    let blob = try await dependencies.blob(target.repositoryURI, target.ref, path)
    if json {
      return CLICommandOutput(stdout: try formatter.json(blob))
    }
    if blob.fileTooLarge {
      throw TangledError.invalidRequest("blob is too large to return: \(blob.path)")
    }
    if let submodule = blob.submodule {
      return CLICommandOutput(
        stdout: formatter.details([
          ("Submodule", submodule.name),
          ("URL", submodule.url),
          ("Branch", submodule.branch),
        ])
      )
    }
    return CLICommandOutput(stdoutData: blob.content ?? Data())
  }

  func languages(
    repository: String?,
    ref: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let target = try await gitTarget(repository: repository, ref: ref)
    let report = try await dependencies.languages(target.repositoryURI, target.ref)
    return CLICommandOutput(
      stdout: try json ? formatter.json(report) : format(report.languages)
    )
  }

  func branches(
    repository: String?,
    cursor: String?,
    limit: Int,
    json: Bool
  ) async throws -> CLICommandOutput {
    let repositoryURI = try await gitRepositoryURI(repository)
    let page = try await dependencies.branches(repositoryURI, cursor, limit)
    return CLICommandOutput(
      stdout: try json ? formatter.json(page) : format(page.items),
      stderr: formatter.cursorDiagnostic(page.cursor, json: json)
    )
  }

  func tags(
    repository: String?,
    cursor: String?,
    limit: Int,
    json: Bool
  ) async throws -> CLICommandOutput {
    let repositoryURI = try await gitRepositoryURI(repository)
    let page = try await dependencies.tags(repositoryURI, cursor, limit)
    return CLICommandOutput(
      stdout: try json ? formatter.json(page) : format(page.items),
      stderr: formatter.cursorDiagnostic(page.cursor, json: json)
    )
  }

  func archive(
    repository: String?,
    ref: String?,
    format: GitArchiveFormat,
    prefix: String?,
    output: String,
    force: Bool
  ) async throws -> CLICommandOutput {
    let destination = URL(fileURLWithPath: output).standardizedFileURL
    try validateArchiveDestination(destination, force: force)

    let target = try await gitTarget(repository: repository, ref: ref)
    let byteCount = try await dependencies.archive(
      target.repositoryURI,
      target.ref,
      format,
      prefix,
      destination
    )
    return CLICommandOutput(
      stdout: "Saved archive to \(output) (\(byteCount) bytes).\n"
    )
  }

  func star(repository: String?) async throws -> CLICommandOutput {
    let repository = try await writableRepository(repository)
    _ = try await dependencies.star(repository.did)
    return CLICommandOutput(
      stdout: "Starred \(repository.description).\n"
    )
  }

  func unstar(repository: String?) async throws -> CLICommandOutput {
    let repository = try await writableRepository(repository)
    let removed = try await dependencies.unstar(repository.did)
    let message =
      removed
      ? "Unstarred \(repository.description).\n"
      : "Repository was not starred: \(repository.description).\n"
    return CLICommandOutput(stdout: message)
  }
}

extension RepoCommandService {
  private struct GitTarget {
    let repositoryURI: String
    let ref: String
  }

  private struct WritableRepository {
    let did: String
    let name: String

    var description: String {
      name == did ? did : "\(name) (\(did))"
    }
  }

  private func writableRepository(_ repository: String?) async throws -> WritableRepository {
    let reference = try repository ?? dependencies.originURL()
    if case .repositoryDID(let did) = try RepositoryReference(reference) {
      return WritableRepository(did: did, name: did)
    }

    let record = try await dependencies.resolveRepository(reference)
    guard let repositoryDID = record.value.repoDID else {
      throw TangledError.invalidRequest("repository has no repo DID")
    }
    return WritableRepository(
      did: repositoryDID,
      name: displayName(record) ?? repositoryDID
    )
  }

  private func gitTarget(repository: String?, ref: String?) async throws -> GitTarget {
    let repositoryURI = try await gitRepositoryURI(repository)
    let resolvedRef: String
    if let ref {
      resolvedRef = ref
    } else {
      resolvedRef = try await dependencies.defaultBranch(repositoryURI).name
    }
    return GitTarget(repositoryURI: repositoryURI, ref: resolvedRef)
  }

  private func gitRepositoryURI(_ repository: String?) async throws -> String {
    let reference = try repository ?? dependencies.originURL()
    return try await dependencies.resolveRepository(reference).uri
  }

  private func validateArchiveDestination(_ destination: URL, force: Bool) throws {
    let fileManager = FileManager.default
    let parent = destination.deletingLastPathComponent()
    var parentIsDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
      parentIsDirectory.boolValue
    else {
      throw ValidationError("output parent directory does not exist: \(parent.path)")
    }

    var destinationIsDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: destination.path,
        isDirectory: &destinationIsDirectory
      )
    else {
      return
    }
    if destinationIsDirectory.boolValue {
      throw ValidationError("output path is a directory: \(destination.path)")
    }
    if !force {
      throw ValidationError(
        "output file already exists: \(destination.path); pass --force to replace it"
      )
    }
  }

  fileprivate func format(_ record: TangledRecord<Repository>) -> String {
    let repository = record.value
    return formatter.details([
      ("Name", displayName(record)),
      ("URI", record.uri),
      ("CID", record.cid),
      ("Repository DID", repository.repoDID),
      ("Knot", repository.knot),
      ("Spindle", repository.spindle),
      ("Description", repository.description),
      ("Website", repository.website),
      ("Source", repository.source),
      ("Topics", repository.topics.joined(separator: ", ")),
      ("Labels", repository.labels.joined(separator: ", ")),
      ("Created", repository.createdAt.rawValue),
    ])
  }

  fileprivate func format(_ repositories: [TangledRecord<Repository>]) -> String {
    let rows = repositories.map { record in
      [
        displayName(record),
        record.value.repoDID,
        record.value.knot,
        record.value.description,
      ]
    }
    return formatter.table(
      headers: ["NAME", "REPO DID", "KNOT", "DESCRIPTION"],
      rows: rows
    )
  }

  fileprivate func format(_ tree: GitTree) -> String {
    formatter.table(
      headers: ["MODE", "SIZE", "NAME", "LAST COMMIT", "MESSAGE"],
      rows: tree.entries.map {
        [
          $0.mode,
          String($0.size),
          $0.name,
          $0.lastCommit?.hash.prefix(7).description,
          $0.lastCommit?.message,
        ]
      }
    )
  }

  fileprivate func format(_ commits: [GitCommit]) -> String {
    formatter.table(
      headers: ["HASH", "DATE", "AUTHOR", "MESSAGE"],
      rows: commits.map {
        [
          $0.hash.prefix(7).description,
          $0.author.when.rawValue,
          $0.author.name,
          $0.message,
        ]
      }
    )
  }

  fileprivate func format(_ languages: [GitLanguage]) -> String {
    formatter.table(
      headers: ["LANGUAGE", "PERCENT", "BYTES", "FILES"],
      rows: languages.map {
        [
          $0.name,
          "\($0.percentage)%",
          String($0.size),
          $0.fileCount.map(String.init),
        ]
      }
    )
  }

  fileprivate func format(_ branches: [GitBranch]) -> String {
    formatter.table(
      headers: ["NAME", "DEFAULT", "HASH", "UPDATED", "AUTHOR", "MESSAGE"],
      rows: branches.map {
        [
          $0.reference.name,
          $0.isDefault ? "yes" : "no",
          $0.reference.hash.prefix(7).description,
          $0.commit?.author.when.rawValue,
          $0.commit?.author.name,
          $0.commit?.message,
        ]
      }
    )
  }

  fileprivate func format(_ tags: [GitTag]) -> String {
    formatter.table(
      headers: ["NAME", "HASH", "TARGET", "DATE", "TAGGER", "MESSAGE"],
      rows: tags.map {
        [
          $0.reference.name,
          $0.reference.hash.prefix(7).description,
          $0.targetHash?.prefix(7).description,
          $0.tagger?.when.rawValue,
          $0.tagger?.name,
          $0.message,
        ]
      }
    )
  }

  fileprivate func displayName(_ record: TangledRecord<Repository>) -> String? {
    record.value.name ?? record.uri.split(separator: "/").last.map(String.init)
  }
}
