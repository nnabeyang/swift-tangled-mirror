import Foundation
import SwiftAtproto
import Testing

@testable import TangledLexicons

@Test func moduleMarkerIsAvailable() {
  _ = TangledLexiconsModule.self
}

@Test func generatedComAtprotoNamespaceCompiles() {
  _ = Com.Atproto.IdentityResolveHandle.id
  #expect(Com.Atproto.IdentityResolveHandle.id == "com.atproto.identity.resolveHandle")
}

@Test func generatedBobbinReadNamespaceCompiles() {
  #expect(Sh.Tangled.ActorGetProfile.id == "sh.tangled.actor.getProfile")
  #expect(Sh.Tangled.RepoGetRepo.id == "sh.tangled.repo.getRepo")
  #expect(Sh.Tangled.SearchQuery.id == "sh.tangled.search.query")
}

@Test func generatedSpindleReadNamespaceCompiles() {
  #expect(Sh.Tangled.CiGetPipeline.id == "sh.tangled.ci.getPipeline")
  #expect(Sh.Tangled.CiQueryPipelines.id == "sh.tangled.ci.queryPipelines")
  #expect(Sh.Tangled.CiQueryPipelines_Kinds_Elem.pullRequest.description == "pull_request")
}

@Test func generatedPullRecordNamespaceCompiles() {
  #expect(Sh.Tangled.RepoPull.nsId == "sh.tangled.repo.pull")
  #expect(Com.Atproto.SyncGetBlob.id == "com.atproto.sync.getBlob")
  #expect(UnknownATPValue.allTypes[Sh.Tangled.RepoPull.nsId] != nil)
  #expect(UnknownATPValue.allTypes[Sh.Tangled.FeedComment.nsId] != nil)
  #expect(UnknownATPValue.allTypes[Sh.Tangled.ActorProfile.nsId] != nil)
}

@Test func generatedArtifactNamespaceCompiles() {
  #expect(Sh.Tangled.RepoArtifact.nsId == "sh.tangled.repo.artifact")
  #expect(Sh.Tangled.RepoListArtifacts.id == "sh.tangled.repo.listArtifacts")
  #expect(Sh.Tangled.RepoCountArtifacts.id == "sh.tangled.repo.countArtifacts")
}

@Test func generatedUnknownValueDecodesScalarSearchScore() throws {
  let data = Data(
    #"{"hits":[{"nsid":"sh.tangled.repo","score":32.5,"uri":"at://did:plc:owner/sh.tangled.repo/core","value":{"$type":"sh.tangled.repo","knot":"knot.example","createdAt":"2026-07-26T00:00:00Z"}}]}"#
      .utf8
  )

  let response = try JSONDecoder().decode(Sh.Tangled.SearchQuery_Output.self, from: data)
  let score = try JSONEncoder().encode(response.hits[0].score)

  #expect(String(decoding: score, as: UTF8.self) == "32.5")
}

@Test func malformedKnownRecordFallsBackToUnknownRecord() throws {
  let data = Data(
    """
    {
      "$type": "sh.tangled.actor.profile",
      "bluesky": false,
      "stats": ["future-stat"]
    }
    """.utf8
  )

  let value = try JSONDecoder().decode(UnknownATPValue.self, from: data)
  let roundTrip = try JSONEncoder().encode(value)
  let raw = try JSONDecoder().decode(RawProfileStats.self, from: roundTrip)
  guard case .record(let record) = value else {
    Issue.record("Expected a record value")
    return
  }
  let unknown = try #require(record as? UnknownRecord)

  #expect(unknown.type == Sh.Tangled.ActorProfile.nsId)
  #expect(raw.stats == ["future-stat"])
}

@Test func generatedPullDecodesLegacyAndModernBlobLinks() throws {
  let legacy = "AAFVEiD2KY2ZLPRMCpZt91auUqPcdZZi3kljHrrSKlpk6kEFng=="
  let modern = "bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a"
  let data = Data(
    """
    {
      "$type": "sh.tangled.repo.pull",
      "title": "Generated links",
      "rounds": [
        {
          "createdAt": "2026-07-26T00:00:00Z",
          "patchBlob": {
            "$type": "blob",
            "ref": "\(legacy)",
            "mimeType": "application/gzip",
            "size": 1
          }
        },
        {
          "createdAt": "2026-07-26T00:01:00Z",
          "patchBlob": {
            "$type": "blob",
            "ref": {"$link": "\(modern)"},
            "mimeType": "application/gzip",
            "size": 2
          }
        }
      ],
      "target": {"branch": "main", "repo": "did:plc:repository"},
      "createdAt": "2026-07-26T00:00:00Z"
    }
    """.utf8
  )

  let pull = try JSONDecoder().decode(Sh.Tangled.RepoPull.self, from: data)

  #expect(
    pull.rounds[0].patchBlob.ref.toBaseEncodedString
      == "bafkreihwfggzslhujqfjm3pxk2xffi64owlgfxsjmmplvurkljsouqifty"
  )
  #expect(pull.rounds[1].patchBlob.ref.toBaseEncodedString == modern)
}

private struct RawProfileStats: Decodable {
  let stats: [String]
}
