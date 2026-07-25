import Foundation
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
}

@Test func generatedArtifactNamespaceCompiles() {
  #expect(Sh.Tangled.RepoArtifact.nsId == "sh.tangled.repo.artifact")
  #expect(Sh.Tangled.RepoListArtifacts.id == "sh.tangled.repo.listArtifacts")
  #expect(Sh.Tangled.RepoCountArtifacts.id == "sh.tangled.repo.countArtifacts")
}

@Test func generatedUnknownValueDecodesScalarSearchScore() throws {
  let data = Data(
    #"{"hits":[{"nsid":"sh.tangled.repo","score":32.5,"uri":"at://did:plc:owner/sh.tangled.repo/core","value":{"$type":"sh.tangled.repo","knot":"knot.example"}}]}"#
      .utf8
  )

  let response = try JSONDecoder().decode(Sh.Tangled.SearchQuery_Output.self, from: data)
  let score = try JSONEncoder().encode(response.hits[0].score)

  #expect(String(decoding: score, as: UTF8.self) == "32.5")
}
