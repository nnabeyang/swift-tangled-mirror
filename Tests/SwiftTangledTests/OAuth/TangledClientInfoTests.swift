import OAuth4Swift
import Testing

@testable import SwiftTangled

@Test func tangledClientInfoDefinesCLIRedirect() {
  let info = OAuth.ClientInfo.tangledCLI(
    boundPort: 54321,
    profile: nil,
    clientID: .hosted(legacyTangledCLIClientID)
  )
  #expect(
    info.clientId
      == "https://soyokaze-pds-rc-677008170211.asia-northeast1.run.app/tangled/cli-client-metadata.json"
  )
  #expect(
    info.scopes == [
      "atproto",
      "repo:sh.tangled.actor.profile",
      "repo:sh.tangled.feed.comment",
      "repo:sh.tangled.feed.reaction",
      "repo:sh.tangled.feed.star",
      "repo:sh.tangled.graph.follow",
      "repo:sh.tangled.graph.vouch",
      "repo:sh.tangled.knot",
      "repo:sh.tangled.knot.member",
      "repo:sh.tangled.label.definition",
      "repo:sh.tangled.label.op",
      "repo:sh.tangled.publicKey",
      "repo:sh.tangled.repo",
      "repo:sh.tangled.repo.artifact",
      "repo:sh.tangled.repo.collaborator",
      "repo:sh.tangled.repo.issue",
      "repo:sh.tangled.repo.issue.comment",
      "repo:sh.tangled.repo.issue.state",
      "repo:sh.tangled.repo.pull",
      "repo:sh.tangled.repo.pull.comment",
      "repo:sh.tangled.repo.pull.status",
      "repo:sh.tangled.spindle",
      "repo:sh.tangled.spindle.member",
      "repo:sh.tangled.string",
      "blob:*/*",
      "rpc:sh.tangled.knot.addMember?aud=*",
      "rpc:sh.tangled.knot.removeMember?aud=*",
      "rpc:sh.tangled.ci.triggerPipeline?aud=*",
      "rpc:sh.tangled.ci.cancelPipeline?aud=*",
      "rpc:sh.tangled.repo.addCollaborator?aud=*",
      "rpc:sh.tangled.repo.addSecret?aud=*",
      "rpc:sh.tangled.repo.create?aud=*",
      "rpc:sh.tangled.repo.delete?aud=*",
      "rpc:sh.tangled.repo.deleteBranch?aud=*",
      "rpc:sh.tangled.repo.forkStatus?aud=*",
      "rpc:sh.tangled.repo.forkSync?aud=*",
      "rpc:sh.tangled.repo.hiddenRef?aud=*",
      "rpc:sh.tangled.repo.listSecrets?aud=*",
      "rpc:sh.tangled.repo.merge?aud=*",
      "rpc:sh.tangled.repo.mergeCheck?aud=*",
      "rpc:sh.tangled.repo.removeCollaborator?aud=*",
      "rpc:sh.tangled.repo.removeSecret?aud=*",
      "rpc:sh.tangled.repo.setDefaultBranch?aud=*",
      "rpc:sh.tangled.repo.push?aud=*",
      "identity:handle",
    ]
  )
  #expect(info.scopes.count == Set(info.scopes).count)
  #expect(!info.scopes.contains("transition:generic"))
  #expect(!info.scopes.contains("repo:*"))
  #expect(info.redirectURI.scheme == "http")
  #expect(info.redirectURI.host == "127.0.0.1")
  #expect(info.redirectURI.port == 54321)
  #expect(info.redirectURI.path == "/callback")
}

@Test func loopbackClientIDIncludesEncodedRedirectAndScopes() {
  let info = OAuth.ClientInfo.tangledCLI(
    boundPort: 54321,
    profile: .ciReporting,
    clientID: .loopback
  )
  #expect(
    info.clientId
      == "http://localhost?redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Fcallback"
      + "&scope=atproto%20identity%3Ahandle%20repo%3Ash.tangled.repo.artifact"
      + "%20repo%3Ash.tangled.feed.comment%20blob%3A%2A%2F%2A"
  )
  #expect(info.clientId.contains("%3A54321%2Fcallback"))
  #expect(!info.clientId.contains("?aud="))
}

@Test func defaultClientIDUsesLoopbackAndEncodesRPCScopes() {
  let info = OAuth.ClientInfo.tangledCLI(boundPort: 49152, profile: nil)
  #expect(defaultTangledLoginClientID == .loopback)
  #expect(info.clientId.hasPrefix("http://localhost?redirect_uri="))
  #expect(info.clientId.contains("%3F"))
  #expect(info.clientId.contains("%3D"))
  #expect(info.clientId.contains("%2A"))
}

@Test func tangledClientInfoUsesCustomHostedClientID() {
  let info = OAuth.ClientInfo.tangledCLI(
    boundPort: 54321,
    profile: nil,
    clientID: .hosted("https://client.example/metadata.json")
  )
  #expect(info.clientId == "https://client.example/metadata.json")
  #expect(info.scopes == OAuth.ClientInfo.cliScopes(profile: nil))
}

@Test func ciReportingProfileUsesOnlyReportingScopes() {
  let info = OAuth.ClientInfo.tangledCLI(boundPort: 54321, profile: .ciReporting)
  #expect(
    info.scopes == [
      "atproto",
      "identity:handle",
      "repo:sh.tangled.repo.artifact",
      "repo:sh.tangled.feed.comment",
      "blob:*/*",
    ]
  )
  #expect(!info.scopes.contains("repo:sh.tangled.repo"))
  #expect(!info.scopes.contains { $0.hasPrefix("rpc:") })
}
