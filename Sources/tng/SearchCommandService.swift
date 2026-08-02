import Foundation
import SwiftTangled

struct SearchCommandDependencies: Sendable {
  let resolveRepository: @Sendable (String) async throws -> TangledRecord<Repository>
  let resolveOwnerDID: @Sendable (String) async throws -> String
  let search: @Sendable (String, SearchOptions) async throws -> Page<SearchHit>
  let coverage: @Sendable () async throws -> BobbinCoverage

  static let live: SearchCommandDependencies = {
    let client = BobbinClient()
    let locator = RepositoryLocator(client: client)
    return SearchCommandDependencies(
      resolveRepository: { try await locator.resolve($0) },
      resolveOwnerDID: { try await locator.resolveOwnerDID($0) },
      search: { try await client.search($0, options: $1) },
      coverage: { try await client.coverage() }
    )
  }()
}

struct SearchCommandService: Sendable {
  private let dependencies: SearchCommandDependencies
  private let formatter: CLIFormatter

  init(
    dependencies: SearchCommandDependencies = .live,
    formatter: CLIFormatter = .plain
  ) {
    self.dependencies = dependencies
    self.formatter = formatter
  }

  func search(
    query: String,
    nsid: String?,
    author: String?,
    repository: String?,
    since: String?,
    until: String?,
    limit: Int,
    cursor: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let dateOptions = SearchOptions(
      since: since.map { .init(rawValue: $0) },
      until: until.map { .init(rawValue: $0) }
    )
    do throws(TangledError) {
      try dateOptions.validateDates()
    } catch {
      throw error
    }

    let authorDID: String?
    if let author {
      authorDID = try await dependencies.resolveOwnerDID(author)
    } else {
      authorDID = nil
    }

    let repositoryDID: String?
    if let repository {
      let record = try await dependencies.resolveRepository(repository)
      guard let resolvedDID = record.value.repoDID, !resolvedDID.isEmpty else {
        throw TangledError.invalidRequest(
          "repository does not expose a repository DID: \(record.uri)"
        )
      }
      repositoryDID = resolvedDID
    } else {
      repositoryDID = nil
    }

    let options = SearchOptions(
      nsid: nsid,
      authorDID: authorDID,
      repoDID: repositoryDID,
      since: dateOptions.since,
      until: dateOptions.until,
      cursor: cursor,
      limit: limit
    )
    async let coverage = readBobbinCoverage(using: dependencies.coverage)
    let page = try await dependencies.search(query, options)
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
}

extension SearchCommandService {
  fileprivate func format(_ hits: [SearchHit]) -> String {
    let rows = hits.map { hit in
      [
        String(hit.score),
        hit.nsid,
        hit.uri,
      ]
    }
    return formatter.table(headers: ["SCORE", "NSID", "URI"], rows: rows)
  }
}
