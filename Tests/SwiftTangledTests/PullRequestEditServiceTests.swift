import Foundation
import SwiftAtproto
import TangledLexicons
import Testing

@testable import SwiftTangled

@Suite struct PullRequestEditServiceTests {
  private let uri =
    "at://did:plc:author/sh.tangled.repo.pull/3edit"

  @Test func prepareReturnsAuthoritativeSnapshot() async throws {
    let snapshot = try makeSnapshot(uri: uri)
    let service = PullRequestEditService(
      dependencies: PullRequestEditDependencies(
        snapshot: { requestedURI in
          #expect(requestedURI == self.uri)
          return snapshot
        },
        update: { _, _, _, _ in
          throw TangledError.transport("unused")
        }
      )
    )

    let context = try await service.prepare(pullRequestURI: uri)

    #expect(context.pullRequest == snapshot.record)
  }

  @Test func prepareRejectsMismatchedPDSRecord() async throws {
    let snapshot = try makeSnapshot(
      uri: "at://did:plc:author/sh.tangled.repo.pull/different"
    )
    let service = PullRequestEditService(
      dependencies: PullRequestEditDependencies(
        snapshot: { _ in snapshot },
        update: { _, _, _, _ in
          throw TangledError.transport("unused")
        }
      )
    )

    await #expect(throws: TangledError.self) {
      _ = try await service.prepare(pullRequestURI: uri)
    }
  }

  private func makeSnapshot(uri: String) throws -> PullRequestRecordSnapshot {
    let data = Data(
      """
      {
        "$type":"sh.tangled.repo.pull",
        "title":"Title",
        "rounds":[{"createdAt":"2026-07-22T12:34:56Z","patchBlob":{"$type":"blob","ref":{"$link":"bafkreigh2akiscaildcw453ukxq2grj32w3w6v3ip5ir6v3g7h4xj5d4te"},"mimeType":"application/gzip","size":42}}],
        "target":{"branch":"main","repo":"did:plc:repository"},
        "createdAt":"2026-07-22T12:34:56Z"
      }
      """.utf8
    )
    let decoder = JSONDecoder()
    decoder.userInfo[.atprotoLexiconDecodingMode] = LexiconDecodingMode.permissive
    let raw = try decoder.decode(UnknownATPValue.self, from: data)
    return PullRequestRecordSnapshot(
      record: try TangledRecordDecoder.pullRequest(
        uri: uri,
        cid: "bafycurrent",
        value: raw
      ),
      rawValue: raw
    )
  }
}
