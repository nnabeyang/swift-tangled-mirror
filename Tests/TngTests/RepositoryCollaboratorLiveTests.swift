import Foundation
import SwiftTangled
import Testing

@testable import tng

@Suite struct RepositoryCollaboratorLiveTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "SWIFT_TANGLED_LIVE_REPOSITORY_COLLABORATOR"
      ] == "1"
    )
  )
  func addListAndRemoveCollaborator() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard
      let repository = environment["SWIFT_TANGLED_LIVE_COLLABORATOR_REPOSITORY"],
      !repository.isEmpty
    else {
      throw RepositoryCollaboratorLiveTestError.missingRepository
    }
    guard
      let collaborator = environment["SWIFT_TANGLED_LIVE_COLLABORATOR_SUBJECT"],
      !collaborator.isEmpty
    else {
      throw RepositoryCollaboratorLiveTestError.missingCollaborator
    }

    let addition = try run([
      "repo", "collaborator", "add", repository, collaborator, "--json",
    ])
    let added = try mutationResult(addition, operation: "add")
    guard added.outcome == .added || added.outcome == .alreadyPresent else {
      throw RepositoryCollaboratorLiveTestError.unexpectedOutcome(added.outcome.rawValue)
    }

    try requireDirectPresence(
      repository: repository,
      collaboratorDID: added.target.collaboratorDID,
      expected: true
    )
    try await requireIndexedPresence(
      repositoryDID: added.target.repositoryDID,
      collaboratorDID: added.target.collaboratorDID,
      expected: true
    )

    let removal = try run([
      "repo", "collaborator", "remove", repository, collaborator, "--yes", "--json",
    ])
    let removed = try mutationResult(removal, operation: "remove")
    guard removed.outcome == .removed else {
      throw RepositoryCollaboratorLiveTestError.unexpectedOutcome(removed.outcome.rawValue)
    }

    try requireDirectPresence(
      repository: repository,
      collaboratorDID: removed.target.collaboratorDID,
      expected: false
    )
    try await requireIndexedPresence(
      repositoryDID: removed.target.repositoryDID,
      collaboratorDID: removed.target.collaboratorDID,
      expected: false
    )
  }

  private func requireDirectPresence(
    repository: String,
    collaboratorDID: String,
    expected: Bool
  ) throws {
    let result = try run([
      "repo", "collaborator", "list", repository, "--limit", "1000", "--json",
    ])
    guard result.status == 0 else {
      throw RepositoryCollaboratorLiveTestError.commandFailed(
        "list: \(result.stderr)\(result.stdout)"
      )
    }
    let page = try JSONDecoder().decode(
      Page<RepositoryCollaborator>.self,
      from: Data(result.stdout.utf8)
    )
    guard page.items.contains(where: { $0.subjectDID == collaboratorDID }) == expected else {
      throw RepositoryCollaboratorLiveTestError.directStateMismatch
    }
  }

  private func requireIndexedPresence(
    repositoryDID: String,
    collaboratorDID: String,
    expected: Bool
  ) async throws {
    for attempt in 0 ..< 15 {
      let result = try run([
        "api", "sh.tangled.repo.listCollaborators", "-f", "subject=\(repositoryDID)",
      ])
      guard result.status == 0 else {
        throw RepositoryCollaboratorLiveTestError.commandFailed(
          "indexed list: \(result.stderr)\(result.stdout)"
        )
      }
      let response = try JSONDecoder().decode(
        IndexedCollaboratorResponse.self,
        from: Data(result.stdout.utf8)
      )
      if response.items.contains(where: { $0.subject == collaboratorDID }) == expected {
        return
      }
      if attempt < 14 {
        try await Task.sleep(for: .seconds(2))
      }
    }
    throw RepositoryCollaboratorLiveTestError.indexedStateMismatch
  }

  private func mutationResult(
    _ process: TngProcessResult,
    operation: String
  ) throws -> RepositoryCollaboratorMutationResult {
    guard process.status == 0 else {
      throw RepositoryCollaboratorLiveTestError.commandFailed(
        "\(operation): \(process.stderr)\(process.stdout)"
      )
    }
    return try JSONDecoder().decode(
      RepositoryJSONEnvelope<RepositoryCollaboratorMutationResult>.self,
      from: Data(process.stdout.utf8)
    ).result
  }

  private func run(_ arguments: [String]) throws -> TngProcessResult {
    try TngProcess.run(arguments)
  }
}

private struct IndexedCollaboratorResponse: Decodable {
  let items: [IndexedCollaborator]
}

private struct IndexedCollaborator: Decodable {
  let subject: String
}

private enum RepositoryCollaboratorLiveTestError: Error {
  case missingRepository
  case missingCollaborator
  case commandFailed(String)
  case unexpectedOutcome(String)
  case directStateMismatch
  case indexedStateMismatch
}
