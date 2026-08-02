import Foundation
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
  public func collaborators(
    repositoryDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<RepositoryCollaborator> {
    let repositoryDID = try collaboratorDID(repositoryDID, name: "repository DID")
    let output = try await generatedQuery {
      try await RepoListCollaborators(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.RepoListCollaborators_Order(rawValue: order.rawValue),
        subject: FormatString(repositoryDID)
      )
    }
    return Page(items: output.items.map(repositoryCollaborator), cursor: output.cursor)
  }

  public func collaboratorCount(repositoryDID: String) async throws -> CountSummary {
    let repositoryDID = try collaboratorDID(repositoryDID, name: "repository DID")
    let output = try await generatedQuery {
      try await RepoCountCollaborators(subject: FormatString(repositoryDID))
    }
    return CountSummary(count: output.count, distinctAuthors: output.distinctAuthors)
  }

  private func collaboratorDID(_ value: String, name: String) throws -> DID {
    do {
      return try DID(string: value)
    } catch {
      throw TangledError.invalidRequest("\(name) must be a valid DID")
    }
  }

  private func repositoryCollaborator(
    _ item: Sh.Tangled.RepoListCollaborators_ListItem
  ) -> RepositoryCollaborator {
    RepositoryCollaborator(
      subjectDID: item.subject.rawValue,
      addedByDID: item.addedBy.rawValue,
      createdAt: item.createdAt,
      recordURI: item.uri?.rawValue,
      recordCID: item.cid?.rawValue
    )
  }
}
