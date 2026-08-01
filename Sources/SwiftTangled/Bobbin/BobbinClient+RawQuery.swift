import Foundation
import HTTPTypes
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
  package static var supportedRawQueryNSIDs: [String] {
    BobbinRawQueryRegistry.responseKinds.keys.sorted()
  }

  package func rawQuery(
    nsid: String,
    queryItems: [URLQueryItem],
    allowsRawResponse: Bool
  ) async throws -> Data {
    guard let responseKind = BobbinRawQueryRegistry.responseKinds[nsid] else {
      throw TangledError.invalidRequest("unsupported Bobbin query NSID: \(nsid)")
    }
    guard responseKind == .json || allowsRawResponse else {
      throw TangledError.invalidRequest("\(nsid) requires --raw")
    }

    var headers = HTTPFields()
    headers[.accept] = responseKind == .raw ? "*/*" : "application/json"
    return try await response(
      XRPCRequestComponents(
        nsId: nsid,
        queryItems: queryItems.map(percentEncodedQueryItem),
        headers: headers,
        method: .get
      )
    )
  }
}

private enum BobbinRawQueryResponseKind: Equatable {
  case json
  case raw
}

private enum BobbinRawQueryRegistry {
  static let responseKinds: [String: BobbinRawQueryResponseKind] = {
    let jsonQueries: [any XRPCQuery.Type] = [
      Sh.Tangled.ActorGetProfile.self,
      Sh.Tangled.ActorGetProfiles.self,
      Sh.Tangled.FeedCountComments.self,
      Sh.Tangled.FeedCountCommentsBy.self,
      Sh.Tangled.FeedCountReactions.self,
      Sh.Tangled.FeedCountReactionsBy.self,
      Sh.Tangled.FeedCountStars.self,
      Sh.Tangled.FeedCountStarsBy.self,
      Sh.Tangled.FeedListComments.self,
      Sh.Tangled.FeedListCommentsBy.self,
      Sh.Tangled.FeedListReactions.self,
      Sh.Tangled.FeedListReactionsBy.self,
      Sh.Tangled.FeedListStars.self,
      Sh.Tangled.FeedListStarsBy.self,
      Sh.Tangled.GraphCountFollows.self,
      Sh.Tangled.GraphCountFollowsBy.self,
      Sh.Tangled.GraphListFollows.self,
      Sh.Tangled.GraphListFollowsBy.self,
      Sh.Tangled.LabelCountDefinitions.self,
      Sh.Tangled.LabelCountOps.self,
      Sh.Tangled.LabelCountOpsBy.self,
      Sh.Tangled.LabelListDefinitions.self,
      Sh.Tangled.LabelListOps.self,
      Sh.Tangled.LabelListOpsBy.self,
      Sh.Tangled.RepoBlob.self,
      Sh.Tangled.RepoBranch.self,
      Sh.Tangled.RepoBranches.self,
      Sh.Tangled.RepoCompare.self,
      Sh.Tangled.RepoCountCollaborators.self,
      Sh.Tangled.RepoCountArtifacts.self,
      Sh.Tangled.RepoCountIssues.self,
      Sh.Tangled.RepoCountIssuesBy.self,
      Sh.Tangled.RepoCountPulls.self,
      Sh.Tangled.RepoCountPullsBy.self,
      Sh.Tangled.RepoCountRepos.self,
      Sh.Tangled.RepoDescribeRepo.self,
      Sh.Tangled.RepoDiff.self,
      Sh.Tangled.RepoGetDefaultBranch.self,
      Sh.Tangled.RepoGetIssue.self,
      Sh.Tangled.RepoGetIssues.self,
      Sh.Tangled.RepoGetPull.self,
      Sh.Tangled.RepoGetPulls.self,
      Sh.Tangled.RepoGetRepo.self,
      Sh.Tangled.RepoGetRepoByRepoDid.self,
      Sh.Tangled.RepoGetRepos.self,
      Sh.Tangled.RepoLanguages.self,
      Sh.Tangled.RepoListCollaborators.self,
      Sh.Tangled.RepoListArtifacts.self,
      Sh.Tangled.RepoListIssues.self,
      Sh.Tangled.RepoListIssuesBy.self,
      Sh.Tangled.RepoListPulls.self,
      Sh.Tangled.RepoListPullsBy.self,
      Sh.Tangled.RepoListRepos.self,
      Sh.Tangled.RepoLog.self,
      Sh.Tangled.RepoTag.self,
      Sh.Tangled.RepoTags.self,
      Sh.Tangled.RepoTree.self,
      Sh.Tangled.SearchQuery.self,
      Sh.Tangled.Repo.IssueCountStates.self,
      Sh.Tangled.Repo.IssueCountStatesBy.self,
      Sh.Tangled.Repo.IssueListStates.self,
      Sh.Tangled.Repo.IssueListStatesBy.self,
      Sh.Tangled.Repo.PullCountStatuses.self,
      Sh.Tangled.Repo.PullCountStatusesBy.self,
      Sh.Tangled.Repo.PullListStatuses.self,
      Sh.Tangled.Repo.PullListStatusesBy.self,
    ]
    var result = Dictionary(
      uniqueKeysWithValues: jsonQueries.map { ($0.id, BobbinRawQueryResponseKind.json) }
    )
    result["sh.tangled.bobbin.getCoverage"] = .json
    result[Sh.Tangled.RepoArchive.id] = .raw
    return result
  }()
}
