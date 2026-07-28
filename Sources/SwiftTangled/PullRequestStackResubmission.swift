import Foundation
import SwiftAtproto

public struct PullRequestStackResubmissionOperation: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case create
    case update
    case delete
    case preserveMerged
  }

  public let kind: Kind
  public let changeID: String
  public let pullRequestURI: String
  public let title: String
  public let previousDependentOn: String?
  public let dependentOn: String?
  public let roundNumber: Int?

  public init(
    kind: Kind,
    changeID: String,
    pullRequestURI: String,
    title: String,
    previousDependentOn: String? = nil,
    dependentOn: String? = nil,
    roundNumber: Int? = nil
  ) {
    self.kind = kind
    self.changeID = changeID
    self.pullRequestURI = pullRequestURI
    self.title = title
    self.previousDependentOn = previousDependentOn
    self.dependentOn = dependentOn
    self.roundNumber = roundNumber
  }
}

public struct PullRequestStackResubmissionPlan: Codable, Equatable, Sendable {
  public let selectedPullRequestURI: String
  public let operations: [PullRequestStackResubmissionOperation]

  public var requiresConfirmation: Bool {
    operations.contains { $0.kind == .delete }
  }

  public init(
    selectedPullRequestURI: String,
    operations: [PullRequestStackResubmissionOperation]
  ) {
    self.selectedPullRequestURI = selectedPullRequestURI
    self.operations = operations
  }
}

public struct PullRequestStackResubmissionResult: Codable, Equatable, Sendable {
  public let plan: PullRequestStackResubmissionPlan
  public let pullRequests: [TangledRecord<PullRequest>]
  public let deletedPullRequestURIs: [String]

  public init(
    plan: PullRequestStackResubmissionPlan,
    pullRequests: [TangledRecord<PullRequest>],
    deletedPullRequestURIs: [String]
  ) {
    self.plan = plan
    self.pullRequests = pullRequests
    self.deletedPullRequestURIs = deletedPullRequestURIs
  }
}

package struct PullRequestStackResubmissionContext: Sendable {
  package let selectedURI: String
  package let expectedRepoCommit: String
  package let snapshots: [String: PullRequestRecordSnapshot]
  package let items: [String: PullRequestListItem]
  package let orderedURIs: [String]

  package var pullRequest: TangledRecord<PullRequest> {
    snapshots[selectedURI]!.record
  }
}

package struct PreparedPullRequestStackResubmission: Sendable {
  package let context: PullRequestStackResubmissionContext
  package let plan: PullRequestStackResubmissionPlan
  package let commitsByURI: [String: PullRequestStackCommit]
}

public struct PullRequestStackResubmissionService: Sendable {
  private let dependencies: PullRequestStackResubmissionDependencies

  public init(
    pdsRecordClient: PDSRecordClient = PDSRecordClient(),
    repositoryLocator: RepositoryLocator = RepositoryLocator(),
    knotClient: KnotClient = KnotClient()
  ) {
    let listService = AuthorPullRequestListService(pdsRecordClient: pdsRecordClient)
    let patchLoader = PullRequestPatchLoader(pdsRecordClient: pdsRecordClient)
    dependencies = PullRequestStackResubmissionDependencies(
      snapshot: { try await pdsRecordClient.pullRequestSnapshot(uri: $0) },
      latestCommit: { try await pdsRecordClient.latestCommit(ownerDID: $0) },
      repository: { try await repositoryLocator.resolve($0) },
      list: {
        try await listService.list(
          repositoryDID: $0,
          repositoryOwnerDID: $1,
          authorDID: $2,
          cursor: $3,
          limit: 100,
          order: .ascending
        )
      },
      patch: { try await patchLoader.load(record: $0).rawPatch },
      updateHiddenRef: {
        try await knotClient.updateHiddenRef(
          knot: $0,
          token: $1,
          repositoryURI: $2,
          sourceBranch: $3,
          targetBranch: $4
        )
      },
      compare: {
        try await knotClient.compare(
          knot: $0,
          repositoryDID: $1,
          baseRevision: $2,
          headRevision: $3
        )
      },
      nextRecordKey: { TID.next().rawValue }
    )
  }

  init(dependencies: PullRequestStackResubmissionDependencies) {
    self.dependencies = dependencies
  }

  package func prepare(
    pullRequestURI: String
  ) async throws -> PullRequestStackResubmissionContext {
    let selected = try await dependencies.snapshot(pullRequestURI)
    guard selected.record.uri == pullRequestURI else {
      throw TangledError.upstreamFailed(
        "PDS returned a different pull request record: \(selected.record.uri)"
      )
    }
    let authorDID = try recordOwnerDID(pullRequestURI)
    let expectedCommit = try await dependencies.latestCommit(authorDID)
    let repository = try await dependencies.repository(
      selected.record.value.target.repositoryDID
    )
    guard repository.value.repoDID == selected.record.value.target.repositoryDID else {
      throw TangledError.upstreamFailed("repository record does not match pull request target")
    }
    let repositoryOwnerDID = try recordOwnerDID(repository.uri)
    let allItems = try await allPullRequests(
      repositoryDID: selected.record.value.target.repositoryDID,
      repositoryOwnerDID: repositoryOwnerDID,
      authorDID: authorDID
    )
    let items = Dictionary(uniqueKeysWithValues: allItems.map { ($0.record.uri, $0) })
    guard items[pullRequestURI] != nil else {
      throw TangledError.notFound("pull request is not present in the author PDS listing")
    }
    let orderedURIs = try orderedStack(containing: pullRequestURI, items: items)
    guard orderedURIs.count > 1 else {
      throw TangledError.invalidRequest("pull request is not part of a stack")
    }

    var snapshots: [String: PullRequestRecordSnapshot] = [:]
    for uri in orderedURIs {
      let item = items[uri]!
      guard item.status == .open || item.status == .merged else {
        throw TangledError.invalidRequest(
          "stack contains a pull request that is not open or merged: \(uri)"
        )
      }
      let snapshot = try await dependencies.snapshot(uri)
      guard snapshot.record.cid == item.record.cid else {
        throw TangledError.conflict("pull request changed while preparing the stack")
      }
      snapshots[uri] = snapshot
    }
    guard try await dependencies.latestCommit(authorDID) == expectedCommit else {
      throw TangledError.conflict("PDS repository changed while preparing the stack")
    }
    return PullRequestStackResubmissionContext(
      selectedURI: pullRequestURI,
      expectedRepoCommit: expectedCommit,
      snapshots: snapshots,
      items: items,
      orderedURIs: orderedURIs
    )
  }

  package func plan(
    _ context: PullRequestStackResubmissionContext,
    commits: [PullRequestStackCommit]
  ) async throws -> PreparedPullRequestStackResubmission {
    guard !commits.isEmpty else {
      throw TangledError.invalidRequest("resubmitted stack must contain at least one commit")
    }
    let newIDs = commits.map(\.changeID)
    guard newIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
      Set(newIDs).count == newIDs.count
    else {
      throw TangledError.invalidRequest(
        "stacked pull requests require a unique Change-Id header in every commit"
      )
    }

    var existingByID: [String: (String, PullRequestRecordSnapshot)] = [:]
    for uri in context.orderedURIs {
      let snapshot = context.snapshots[uri]!
      let patch = try await dependencies.patch(snapshot.record)
      let changeID = try FormatPatchSeries.changeID(in: patch)
      guard existingByID[changeID] == nil else {
        throw TangledError.invalidRequest("existing stack contains duplicate change IDs")
      }
      existingByID[changeID] = (uri, snapshot)
    }

    let authorDID = try recordOwnerDID(context.selectedURI)
    var assigned: [(PullRequestStackCommit, String, PullRequestRecordSnapshot?)] = []
    for commit in commits {
      if let existing = existingByID[commit.changeID] {
        assigned.append((commit, existing.0, existing.1))
      } else {
        assigned.append(
          (
            commit,
            "at://\(authorDID)/sh.tangled.repo.pull/\(dependencies.nextRecordKey())",
            nil
          )
        )
      }
    }

    var operations: [PullRequestStackResubmissionOperation] = []
    var commitsByURI: [String: PullRequestStackCommit] = [:]
    var parent: String?
    for (commit, uri, snapshot) in assigned {
      commitsByURI[uri] = commit
      if let snapshot {
        let status = context.items[uri]!.status
        if status == .merged {
          guard snapshot.record.value.dependentOn == parent else {
            throw TangledError.invalidRequest(
              "resubmission would change a merged pull request dependency"
            )
          }
          operations.append(
            .init(
              kind: .preserveMerged,
              changeID: commit.changeID,
              pullRequestURI: uri,
              title: snapshot.record.value.title,
              previousDependentOn: snapshot.record.value.dependentOn,
              dependentOn: parent
            )
          )
        } else {
          operations.append(
            .init(
              kind: .update,
              changeID: commit.changeID,
              pullRequestURI: uri,
              title: commit.title,
              previousDependentOn: snapshot.record.value.dependentOn,
              dependentOn: parent,
              roundNumber: snapshot.record.value.rounds.count
            )
          )
        }
      } else {
        operations.append(
          .init(
            kind: .create,
            changeID: commit.changeID,
            pullRequestURI: uri,
            title: commit.title,
            dependentOn: parent,
            roundNumber: 0
          )
        )
      }
      parent = uri
    }

    let retained = Set(newIDs)
    for uri in context.orderedURIs {
      let snapshot = context.snapshots[uri]!
      let patch = try await dependencies.patch(snapshot.record)
      let changeID = try FormatPatchSeries.changeID(in: patch)
      guard !retained.contains(changeID) else { continue }
      let status = context.items[uri]!.status
      operations.append(
        .init(
          kind: status == .merged ? .preserveMerged : .delete,
          changeID: changeID,
          pullRequestURI: uri,
          title: snapshot.record.value.title,
          previousDependentOn: snapshot.record.value.dependentOn
        )
      )
    }
    return PreparedPullRequestStackResubmission(
      context: context,
      plan: .init(selectedPullRequestURI: context.selectedURI, operations: operations),
      commitsByURI: commitsByURI
    )
  }

  package func forkCommits(
    _ context: PullRequestStackResubmissionContext,
    pdsClient: PDSClient
  ) async throws -> [PullRequestStackCommit] {
    let pull = context.pullRequest.value
    guard let source = pull.source, let sourceRepositoryDID = source.repositoryDID else {
      throw TangledError.invalidRequest(
        "fork stack resubmission requires a fork-based pull request"
      )
    }
    let sourceRepository = try await dependencies.repository(sourceRepositoryDID)
    guard sourceRepository.value.repoDID == sourceRepositoryDID,
      let upstream = sourceRepository.value.source
    else {
      throw TangledError.invalidRequest("source repository is not declared as a fork")
    }
    let upstreamRepository = try await dependencies.repository(upstream)
    guard upstreamRepository.value.repoDID == pull.target.repositoryDID else {
      throw TangledError.invalidRequest(
        "source repository fork metadata points to a different target repository"
      )
    }
    let audience = try knotServiceAudience(sourceRepository.value.knot)
    let token = try await pdsClient.serviceAuthToken(
      audience: audience,
      lxm: "sh.tangled.repo.hiddenRef"
    )
    let hidden = try await dependencies.updateHiddenRef(
      sourceRepository.value.knot,
      token,
      sourceRepository.uri,
      source.branch,
      pull.target.branch
    )
    let comparison = try await dependencies.compare(
      sourceRepository.value.knot,
      sourceRepositoryDID,
      hidden,
      source.branch
    )
    return try comparison.formatPatches.map { patch in
      let ids =
        patch.headers.first {
          $0.key.caseInsensitiveCompare("Change-Id") == .orderedSame
        }?.value ?? []
      guard ids.count == 1, let changeID = ids.first, !changeID.isEmpty else {
        throw TangledError.invalidRequest(
          "stacked pull requests require exactly one Change-Id header in every patch"
        )
      }
      return PullRequestStackCommit(
        title: patch.title,
        body: patch.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? nil : patch.body,
        changeID: changeID,
        patch: Data(patch.raw.utf8)
      )
    }
  }

  private func allPullRequests(
    repositoryDID: String,
    repositoryOwnerDID: String,
    authorDID: String
  ) async throws -> [PullRequestListItem] {
    var items: [PullRequestListItem] = []
    var cursor: String?
    var seen = Set<String>()
    repeat {
      let page = try await dependencies.list(
        repositoryDID,
        repositoryOwnerDID,
        authorDID,
        cursor
      )
      items.append(contentsOf: page.items)
      guard let next = page.cursor else { break }
      guard seen.insert(next).inserted else {
        throw TangledError.upstreamFailed("PDS returned a repeated pull request pagination cursor")
      }
      cursor = next
    } while true
    return items
  }

  private func orderedStack(
    containing selected: String,
    items: [String: PullRequestListItem]
  ) throws -> [String] {
    var bottom = selected
    var visited = Set<String>()
    while let parent = items[bottom]?.record.value.dependentOn {
      guard visited.insert(bottom).inserted else {
        throw TangledError.invalidRequest("pull request stack contains a dependency cycle")
      }
      guard items[parent] != nil else {
        throw TangledError.invalidRequest("pull request stack is missing dependency \(parent)")
      }
      bottom = parent
    }
    var ordered: [String] = []
    var current: String? = bottom
    visited.removeAll()
    while let uri = current {
      guard visited.insert(uri).inserted else {
        throw TangledError.invalidRequest("pull request stack contains a dependency cycle")
      }
      ordered.append(uri)
      let children = items.values.filter { $0.record.value.dependentOn == uri }
      guard children.count <= 1 else {
        throw TangledError.invalidRequest("pull request stack contains multiple dependents")
      }
      current = children.first?.record.uri
    }
    return ordered
  }

  private func recordOwnerDID(_ rawURI: String) throws -> String {
    let uri = try ATURI(string: rawURI)
    guard case .did(let did) = uri.authority, uri.rkey != nil else {
      throw TangledError.invalidRequest("record URI must be owned by a DID")
    }
    return did.rawValue
  }
}

struct PullRequestStackResubmissionDependencies: Sendable {
  let snapshot: @Sendable (String) async throws -> PullRequestRecordSnapshot
  let latestCommit: @Sendable (String) async throws -> String
  let repository: @Sendable (String) async throws -> TangledRecord<Repository>
  let list: @Sendable (String, String, String, String?) async throws -> Page<PullRequestListItem>
  let patch: @Sendable (TangledRecord<PullRequest>) async throws -> Data
  let updateHiddenRef: @Sendable (String, String, String, String, String) async throws -> String
  let compare: @Sendable (String, String, String, String) async throws -> GitComparison
  let nextRecordKey: @Sendable () -> String
}

package enum FormatPatchSeries {
  package static func changeID(in data: Data) throws -> String {
    guard let text = String(data: data, encoding: .utf8) else {
      throw TangledError.invalidRequest("pull request patch must be valid UTF-8")
    }
    var values: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
      if line.isEmpty { break }
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count == 2, parts[0].caseInsensitiveCompare("Change-Id") == .orderedSame {
        let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { values.append(value) }
      }
    }
    guard values.count == 1 else {
      throw TangledError.invalidRequest(
        "stacked pull requests require exactly one Change-Id header in every patch"
      )
    }
    return values[0]
  }

  package static func parse(_ data: Data) throws -> [PullRequestStackCommit] {
    guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
      throw TangledError.invalidRequest("pull request patch must be valid UTF-8")
    }
    let marker = " Mon Sep 17 00:00:00 2001"
    var chunks: [[String]] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      if line.hasPrefix("From "), line.hasSuffix(marker) { chunks.append([]) }
      guard !chunks.isEmpty else { continue }
      chunks[chunks.count - 1].append(line)
    }
    guard !chunks.isEmpty else {
      throw TangledError.invalidRequest("stack resubmission requires git format-patches")
    }
    return try chunks.map { lines in
      let raw = Data((lines.joined(separator: "\n") + "\n").utf8)
      let changeID = try changeID(in: raw)
      guard let subject = lines.first(where: { $0.hasPrefix("Subject: ") }) else {
        throw TangledError.invalidRequest("format-patch is missing Subject")
      }
      var title = String(subject.dropFirst("Subject: ".count))
      if title.hasPrefix("[") {
        guard let end = title.firstIndex(of: "]") else {
          throw TangledError.invalidRequest("format-patch has an invalid Subject")
        }
        title = String(title[title.index(after: end)...]).trimmingCharacters(in: .whitespaces)
      }
      let headerEnd = lines.firstIndex(of: "") ?? lines.endIndex
      let bodyStart = headerEnd < lines.endIndex ? lines.index(after: headerEnd) : lines.endIndex
      let separator =
        lines[bodyStart...].firstIndex(of: "---")
        ?? lines[bodyStart...].firstIndex(where: { $0.hasPrefix("--- ") })
        ?? lines.endIndex
      let body = lines[bodyStart ..< separator]
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return PullRequestStackCommit(
        title: title,
        body: body.isEmpty ? nil : body,
        changeID: changeID,
        patch: raw
      )
    }
  }
}
