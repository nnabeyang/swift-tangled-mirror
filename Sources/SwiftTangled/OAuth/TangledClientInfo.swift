import Foundation
import OAuth4Swift
import TangledLexicons

public let tangledCLIScopes = [
  "atproto",
  "repo:\(Sh.Tangled.ActorProfile.nsId)",
  "repo:\(Sh.Tangled.FeedComment.nsId)",
  "repo:\(Sh.Tangled.FeedReaction.nsId)",
  "repo:\(Sh.Tangled.FeedStar.nsId)",
  "repo:\(Sh.Tangled.GraphFollow.nsId)",
  "repo:sh.tangled.graph.vouch",
  "repo:sh.tangled.knot",
  "repo:sh.tangled.knot.member",
  "repo:\(Sh.Tangled.LabelDefinition.nsId)",
  "repo:\(Sh.Tangled.LabelOp.nsId)",
  "repo:sh.tangled.publicKey",
  "repo:\(Sh.Tangled.Repo.nsId)",
  "repo:\(Sh.Tangled.RepoArtifact.nsId)",
  "repo:sh.tangled.repo.collaborator",
  "repo:\(Sh.Tangled.RepoIssue.nsId)",
  "repo:sh.tangled.repo.issue.comment",
  "repo:\(Sh.Tangled.Repo.IssueState.nsId)",
  "repo:\(Sh.Tangled.RepoPull.nsId)",
  "repo:sh.tangled.repo.pull.comment",
  "repo:\(Sh.Tangled.Repo.PullStatus.nsId)",
  "repo:sh.tangled.spindle",
  "repo:sh.tangled.spindle.member",
  "repo:sh.tangled.string",
  "blob:*/*",
  "rpc:sh.tangled.knot.addMember?aud=*",
  "rpc:sh.tangled.knot.removeMember?aud=*",
  "rpc:\(Sh.Tangled.CiTriggerPipeline.id)?aud=*",
  "rpc:\(Sh.Tangled.CiCancelPipeline.id)?aud=*",
  "rpc:sh.tangled.repo.addCollaborator?aud=*",
  "rpc:sh.tangled.repo.addSecret?aud=*",
  "rpc:sh.tangled.repo.create?aud=*",
  "rpc:sh.tangled.repo.delete?aud=*",
  "rpc:sh.tangled.repo.deleteBranch?aud=*",
  "rpc:sh.tangled.repo.forkStatus?aud=*",
  "rpc:sh.tangled.repo.forkSync?aud=*",
  "rpc:\(Sh.Tangled.RepoHiddenRef.id)?aud=*",
  "rpc:sh.tangled.repo.listSecrets?aud=*",
  "rpc:\(Sh.Tangled.RepoMerge.id)?aud=*",
  "rpc:\(Sh.Tangled.RepoMergeCheck.id)?aud=*",
  "rpc:sh.tangled.repo.removeCollaborator?aud=*",
  "rpc:sh.tangled.repo.removeSecret?aud=*",
  "rpc:sh.tangled.repo.setDefaultBranch?aud=*",
  "rpc:sh.tangled.repo.push?aud=*",
  "identity:handle",
]

public let tangledCIReportingScopes = [
  "atproto",
  "identity:handle",
  "repo:\(Sh.Tangled.RepoArtifact.nsId)",
  "repo:\(Sh.Tangled.FeedComment.nsId)",
  "blob:*/*",
]

public let legacyTangledCLIClientID =
  "https://soyokaze-pds-rc-677008170211.asia-northeast1.run.app/tangled/cli-client-metadata.json"

public enum TangledClientID: Sendable, Equatable {
  case hosted(String)

  fileprivate func value(redirectURI _: URL, scopes _: [String]) -> String {
    switch self {
    case .hosted(let clientID): clientID
    }
  }
}

public let defaultTangledLoginClientID = TangledClientID.hosted(legacyTangledCLIClientID)

extension OAuth.ClientInfo {
  public static func tangledCLI(
    boundPort: UInt16,
    profile: AuthenticationProfile?,
    clientID: TangledClientID = defaultTangledLoginClientID
  ) -> OAuth.ClientInfo {
    let scopes = cliScopes(profile: profile)
    let redirectURI = URL(string: "http://127.0.0.1:\(boundPort)/callback")!
    return OAuth.ClientInfo(
      clientId: clientID.value(redirectURI: redirectURI, scopes: scopes),
      scopes: scopes,
      redirectURI: redirectURI
    )
  }

  public static func cliScopes(profile: AuthenticationProfile?) -> [String] {
    profile == .ciReporting ? tangledCIReportingScopes : tangledCLIScopes
  }
}
