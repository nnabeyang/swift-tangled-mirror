import Foundation
import SwiftAtproto
import Testing

@testable import SwiftTangled

@Suite struct AuthorPullRequestListServiceTests {
  @Test func derivesAuthorizedStatusAndFiltersRepository() async throws {
    let matching = pull("one", repositoryDID: repositoryDID, createdAt: "2026-07-26T01:00:00Z")
    let other = pull("other", repositoryDID: "did:plc:other", createdAt: "2026-07-26T02:00:00Z")
    let service = AuthorPullRequestListService(
      loadPullRequests: { _, _, _, _ in Page(items: [matching, other]) },
      loadStatuses: { owner, _, _, _ in
        switch owner {
        case authorDID:
          Page(items: [
            status(matching.uri, .closed, "author-old", "2026-07-26T03:00:00Z")
          ])
        case repositoryOwnerDID:
          Page(items: [
            status(matching.uri, .merged, "owner-new", "2026-07-26T04:00:00Z")
          ])
        default:
          Page(items: [])
        }
      }
    )

    let page = try await service.list(
      repositoryDID: repositoryDID,
      repositoryOwnerDID: repositoryOwnerDID,
      authorDID: authorDID,
      status: .merged
    )

    #expect(page.items.map(\.record.uri) == [matching.uri])
    #expect(page.items.first?.status == .merged)
    #expect(page.items.first?.commentCount == -1)
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any]
    )
    let items = try #require(object["items"] as? [[String: Any]])
    #expect(items.first?["commentCount"] as? Int == -1)
  }

  @Test func integratedCursorPagesWithoutDuplicatesAndRejectsOtherInputs() async throws {
    let pulls = [
      pull("one", repositoryDID: repositoryDID, createdAt: "2026-07-26T01:00:00Z"),
      pull("two", repositoryDID: repositoryDID, createdAt: "2026-07-26T02:00:00Z"),
      pull("three", repositoryDID: repositoryDID, createdAt: "2026-07-26T03:00:00Z"),
    ]
    let service = AuthorPullRequestListService(
      loadPullRequests: { _, _, _, _ in Page(items: pulls) },
      loadStatuses: { _, _, _, _ in Page(items: []) }
    )

    let first = try await service.list(
      repositoryDID: repositoryDID,
      repositoryOwnerDID: repositoryOwnerDID,
      authorDID: authorDID,
      limit: 2
    )
    let cursor = try #require(first.cursor)
    let second = try await service.list(
      repositoryDID: repositoryDID,
      repositoryOwnerDID: repositoryOwnerDID,
      authorDID: authorDID,
      cursor: cursor,
      limit: 2
    )

    #expect(first.items.map(\.record.uri) == [pulls[2].uri, pulls[1].uri])
    #expect(second.items.map(\.record.uri) == [pulls[0].uri])
    #expect(second.cursor == nil)
    await #expect(throws: TangledError.self) {
      _ = try await service.list(
        repositoryDID: repositoryDID,
        repositoryOwnerDID: repositoryOwnerDID,
        authorDID: authorDID,
        cursor: "bobbin-cursor"
      )
    }
    await #expect(throws: TangledError.self) {
      _ = try await service.list(
        repositoryDID: repositoryDID,
        repositoryOwnerDID: repositoryOwnerDID,
        authorDID: authorDID,
        cursor: cursor,
        order: .ascending
      )
    }
  }

  @Test func followsEveryPDSPageAndRejectsRepeatedCursor() async throws {
    let recorder = PageRecorder()
    let service = AuthorPullRequestListService(
      loadPullRequests: { _, cursor, _, _ in
        await recorder.record(cursor)
        return cursor == nil
          ? Page(
            items: [
              pull("one", repositoryDID: repositoryDID, createdAt: "2026-07-26T01:00:00Z")
            ],
            cursor: "next"
          )
          : Page(
            items: [
              pull("two", repositoryDID: repositoryDID, createdAt: "2026-07-26T02:00:00Z")
            ]
          )
      },
      loadStatuses: { _, _, _, _ in Page(items: []) }
    )

    let page = try await service.list(
      repositoryDID: repositoryDID,
      repositoryOwnerDID: authorDID,
      authorDID: authorDID
    )
    #expect(page.items.count == 2)
    #expect(await recorder.values() == [nil, "next"])

    let repeated = AuthorPullRequestListService(
      loadPullRequests: { _, _, _, _ in Page(items: [], cursor: "same") },
      loadStatuses: { _, _, _, _ in Page(items: []) }
    )
    await #expect(throws: TangledError.self) {
      _ = try await repeated.list(
        repositoryDID: repositoryDID,
        repositoryOwnerDID: authorDID,
        authorDID: authorDID
      )
    }
  }
}

private let authorDID = "did:plc:author"
private let repositoryOwnerDID = "did:plc:owner"
private let repositoryDID = "did:plc:repository"

private func pull(
  _ rkey: String,
  repositoryDID: String,
  createdAt: String
) -> TangledRecord<PullRequest> {
  TangledRecord(
    uri: "at://\(authorDID)/sh.tangled.repo.pull/\(rkey)",
    value: PullRequest(
      title: rkey,
      rounds: [],
      target: PullRequestTarget(branch: "main", repositoryDID: repositoryDID),
      createdAt: FormatString<Date>(rawValue: createdAt)
    )
  )
}

private func status(
  _ pullRequestURI: String,
  _ value: PullRequestStatus,
  _ rkey: String,
  _ createdAt: String
) -> TangledRecord<PullRequestStatusChange> {
  TangledRecord(
    uri: "at://\(repositoryOwnerDID)/sh.tangled.repo.pull.status/\(rkey)",
    value: PullRequestStatusChange(
      pullRequestURI: pullRequestURI,
      status: value,
      createdAt: FormatString<Date>(rawValue: createdAt)
    )
  )
}

private actor PageRecorder {
  private var cursors: [String?] = []

  func record(_ cursor: String?) {
    cursors.append(cursor)
  }

  func values() -> [String?] {
    cursors
  }
}
