import Foundation
import SwiftTangled
import Testing

@testable import tng

@Suite struct SearchCommandTests {
  @Test func parsesQueryAndFilters() throws {
    let command = try SearchCommand.parse([
      "tangled swift",
      "--nsid", "sh.tangled.repo",
      "--author", "alice.example",
      "--repository", "alice.example/core",
      "--since", "2026-01-01T00:00:00Z",
      "--until", "2026-07-01T00:00:00Z",
      "--limit", "25",
      "--cursor", "previous",
      "--json",
    ])

    #expect(command.query == "tangled swift")
    #expect(command.nsid == "sh.tangled.repo")
    #expect(command.author == "alice.example")
    #expect(command.repository == "alice.example/core")
    #expect(command.since == "2026-01-01T00:00:00Z")
    #expect(command.until == "2026-07-01T00:00:00Z")
    #expect(command.limit == 25)
    #expect(command.cursor == "previous")
    #expect(command.json)

    #expect(throws: (any Error).self) {
      _ = try SearchCommand.parse(["swift", "--limit", "0"])
    }
  }

  @Test func resolvesAuthorAndRepositoryAndFormatsResults() async throws {
    let recorder = SearchCommandRecorder()
    let service = SearchCommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.search(
      query: "tangled swift",
      nsid: "sh.tangled.repo",
      author: "alice.example",
      repository: "alice.example/core",
      since: "2026-01-01T00:00:00Z",
      until: "2026-07-01T00:00:00Z",
      limit: 25,
      cursor: "previous",
      json: false
    )

    #expect(output.stdout.hasPrefix("SCORE\tNSID\tURI\n"))
    #expect(
      output.stdout.contains(
        "32.904587\tsh.tangled.repo\tat://did:plc:owner/sh.tangled.repo/core"
      )
    )
    #expect(output.stderr == "Next cursor: next-page\n")
    #expect(await recorder.owners() == ["alice.example"])
    #expect(await recorder.repositories() == ["alice.example/core"])

    let call = try #require(await recorder.searches().first)
    #expect(call.query == "tangled swift")
    #expect(call.options.nsid == "sh.tangled.repo")
    #expect(call.options.authorDID == "did:plc:resolved-author")
    #expect(call.options.repoDID == "did:plc:repository")
    #expect(call.options.since?.rawValue == "2026-01-01T00:00:00Z")
    #expect(call.options.until?.rawValue == "2026-07-01T00:00:00Z")
    #expect(call.options.limit == 25)
    #expect(call.options.cursor == "previous")
  }

  @Test func unfilteredJSONPreservesCompletePage() async throws {
    let recorder = SearchCommandRecorder()
    let service = SearchCommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.search(
      query: "swift",
      nsid: nil,
      author: nil,
      repository: nil,
      since: nil,
      until: nil,
      limit: 30,
      cursor: nil,
      json: true
    )

    let page = try JSONDecoder().decode(Page<SearchHit>.self, from: Data(output.stdout.utf8))
    #expect(page.cursor == "next-page")
    #expect(page.items.count == 2)
    #expect(
      page.items[1].value
        == .object([
          "enabled": .bool(true),
          "tags": .array([.string("swift"), .string("atproto")]),
        ])
    )
    #expect(output.stderr.isEmpty)
    #expect(await recorder.owners().isEmpty)
    #expect(await recorder.repositories().isEmpty)

    let options = try #require(await recorder.searches().first?.options)
    #expect(options.authorDID == nil)
    #expect(options.repoDID == nil)
    #expect(options.limit == 30)
  }

  @Test func emptyResultsKeepHeaderAndOmitCursor() async throws {
    let recorder = SearchCommandRecorder()
    let service = SearchCommandService(
      dependencies: dependencies(
        recorder: recorder,
        page: Page(items: [], cursor: nil)
      )
    )

    let output = try await service.search(
      query: "missing",
      nsid: nil,
      author: nil,
      repository: nil,
      since: nil,
      until: nil,
      limit: 30,
      cursor: nil,
      json: false
    )

    #expect(output.stdout == "SCORE\tNSID\tURI\n")
    #expect(output.stderr.contains("Bobbin returned no results"))
  }

  @Test func warmingCoverageWarnsForNonemptyResults() async throws {
    let recorder = SearchCommandRecorder()
    let service = SearchCommandService(
      dependencies: dependencies(
        recorder: recorder,
        coverage: {
          BobbinCoverage(ready: false, eventsProcessed: 45, lastCursor: 51)
        }
      )
    )

    let output = try await service.search(
      query: "swift",
      nsid: nil,
      author: nil,
      repository: nil,
      since: nil,
      until: nil,
      limit: 30,
      cursor: nil,
      json: true
    )

    #expect(output.stdout.contains("\"items\""))
    #expect(output.stderr.contains("coverage is not ready"))
  }

  @Test func repositoryWithoutDIDFailsBeforeSearch() async {
    let recorder = SearchCommandRecorder()
    let repository = sampleRepositoryRecord(repositoryDID: nil)
    let service = SearchCommandService(
      dependencies: dependencies(recorder: recorder, repositoryRecord: repository)
    )

    await #expect(throws: TangledError.self) {
      _ = try await service.search(
        query: "swift",
        nsid: nil,
        author: nil,
        repository: "alice.example/core",
        since: nil,
        until: nil,
        limit: 30,
        cursor: nil,
        json: false
      )
    }
    #expect(await recorder.searches().isEmpty)
  }

  @Test func invalidDateRangesFailBeforeSearch() async {
    let recorder = SearchCommandRecorder()
    let service = SearchCommandService(dependencies: dependencies(recorder: recorder))

    await #expect(throws: TangledError.self) {
      _ = try await service.search(
        query: "swift",
        nsid: nil,
        author: "alice.example",
        repository: "alice.example/core",
        since: "not-a-date",
        until: nil,
        limit: 30,
        cursor: nil,
        json: false
      )
    }
    await #expect(throws: TangledError.self) {
      _ = try await service.search(
        query: "swift",
        nsid: nil,
        author: nil,
        repository: nil,
        since: "2026-07-01T00:00:00Z",
        until: "2026-01-01T00:00:00Z",
        limit: 30,
        cursor: nil,
        json: false
      )
    }
    #expect(await recorder.owners().isEmpty)
    #expect(await recorder.repositories().isEmpty)
    #expect(await recorder.searches().isEmpty)
  }
}

extension SearchCommandTests {
  fileprivate func dependencies(
    recorder: SearchCommandRecorder,
    repositoryRecord: TangledRecord<Repository>? = nil,
    page: Page<SearchHit>? = nil,
    coverage: @escaping @Sendable () async throws -> BobbinCoverage = {
      BobbinCoverage(ready: true, eventsProcessed: 100, lastCursor: 100)
    }
  ) -> SearchCommandDependencies {
    let repositoryRecord = repositoryRecord ?? sampleRepositoryRecord()
    let page = page ?? samplePage()
    return SearchCommandDependencies(
      resolveRepository: { reference in
        await recorder.record(repository: reference)
        return repositoryRecord
      },
      resolveOwnerDID: { owner in
        await recorder.record(owner: owner)
        return owner.hasPrefix("did:") ? owner : "did:plc:resolved-author"
      },
      search: { query, options in
        await recorder.record(search: .init(query: query, options: options))
        return page
      },
      coverage: coverage
    )
  }

  fileprivate func sampleRepositoryRecord(
    repositoryDID: String? = "did:plc:repository"
  ) -> TangledRecord<Repository> {
    TangledRecord(
      uri: "at://did:plc:owner/sh.tangled.repo/core",
      value: Repository(
        name: "core",
        knot: "knot1.tangled.sh",
        repoDID: repositoryDID,
        createdAt: .init(rawValue: "2026-03-30T09:14:36Z")
      )
    )
  }

  fileprivate func samplePage() -> Page<SearchHit> {
    Page(
      items: [
        SearchHit(
          uri: "at://did:plc:owner/sh.tangled.repo/core",
          cid: "bafyreirepository",
          nsid: "sh.tangled.repo",
          score: 32.904587,
          value: .object(["name": .string("core")])
        ),
        SearchHit(
          uri: "at://did:plc:author/sh.tangled.example/item",
          nsid: "sh.tangled.example",
          score: 4,
          value: .object([
            "enabled": .bool(true),
            "tags": .array([.string("swift"), .string("atproto")]),
          ])
        ),
      ],
      cursor: "next-page"
    )
  }
}

private actor SearchCommandRecorder {
  struct SearchCall: Equatable, Sendable {
    let query: String
    let options: SearchOptions
  }

  private var recordedOwners: [String] = []
  private var recordedRepositories: [String] = []
  private var recordedSearches: [SearchCall] = []

  func record(owner: String) {
    recordedOwners.append(owner)
  }

  func record(repository: String) {
    recordedRepositories.append(repository)
  }

  func record(search: SearchCall) {
    recordedSearches.append(search)
  }

  func owners() -> [String] {
    recordedOwners
  }

  func repositories() -> [String] {
    recordedRepositories
  }

  func searches() -> [SearchCall] {
    recordedSearches
  }
}
