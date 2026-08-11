import ArgumentParser
import Foundation
import SwiftTangled

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct RepoCollaboratorCommandDependencies: Sendable {
  let list:
    @Sendable (String, String?, Int, BobbinSortOrder) async throws -> Page<
      RepositoryCollaborator
    >
  let add: @Sendable (String, String) async throws -> RepositoryCollaboratorMutationResult
  let prepareRemoval: @Sendable (String, String) async throws -> RepositoryCollaboratorRemovalPlan
  let remove:
    @Sendable (RepositoryCollaboratorRemovalPlan) async throws
      -> RepositoryCollaboratorMutationResult
  let originURL: @Sendable () throws -> String
  let inputIsTerminal: @Sendable () -> Bool
  let confirmRemoval: @Sendable (RepositoryCollaboratorTarget) -> Bool

  static let live: RepoCollaboratorCommandDependencies = {
    let service = RepositoryCollaboratorService()
    return RepoCollaboratorCommandDependencies(
      list: { repository, cursor, limit, order in
        try await service.collaborators(
          repository: repository,
          cursor: cursor,
          limit: limit,
          order: order
        )
      },
      add: { repository, collaborator in
        let pdsClient = try await CLIAuthenticatedClient.make()
        return try await service.add(
          repository: repository,
          collaborator: collaborator,
          pdsClient: pdsClient
        )
      },
      prepareRemoval: { repository, collaborator in
        let pdsClient = try await CLIAuthenticatedClient.make()
        return try await service.prepareRemoval(
          repository: repository,
          collaborator: collaborator,
          pdsClient: pdsClient
        )
      },
      remove: { plan in
        let pdsClient = try await CLIAuthenticatedClient.make()
        return try await service.remove(plan, pdsClient: pdsClient)
      },
      originURL: { try GitOriginReader().read() },
      inputIsTerminal: { collaboratorStandardInputIsTerminal() },
      confirmRemoval: { promptForCollaboratorRemoval($0) }
    )
  }()
}

struct RepoCollaboratorCommandService: Sendable {
  private let dependencies: RepoCollaboratorCommandDependencies
  private let formatter: CLIFormatter

  init(
    dependencies: RepoCollaboratorCommandDependencies = .live,
    formatter: CLIFormatter = .plain
  ) {
    self.dependencies = dependencies
    self.formatter = formatter
  }

  func list(
    repository: String?,
    cursor: String?,
    limit: Int,
    sort: BobbinSortOrder,
    json: Bool
  ) async throws -> CLICommandOutput {
    let repository = try repository ?? dependencies.originURL()
    let page = try await dependencies.list(repository, cursor, limit, sort)
    return CLICommandOutput(
      stdout: try json ? formatter.json(page) : format(page.items),
      stderr: formatter.cursorDiagnostic(page.cursor, json: json)
    )
  }

  func add(
    repository: String,
    collaborator: String,
    json: Bool
  ) async throws -> CLICommandOutput {
    let result = try await dependencies.add(repository, collaborator)
    return try mutationOutput(result, json: json)
  }

  func remove(
    repository: String,
    collaborator: String,
    confirmed: Bool,
    json: Bool
  ) async throws -> CLICommandOutput {
    let plan = try await dependencies.prepareRemoval(repository, collaborator)
    guard plan.isPresent else {
      return try mutationOutput(
        RepositoryCollaboratorMutationResult(outcome: .notPresent, target: plan.target),
        json: json
      )
    }
    if !confirmed {
      guard dependencies.inputIsTerminal() else {
        throw ValidationError("--yes is required when standard input is not a terminal")
      }
      guard dependencies.confirmRemoval(plan.target) else {
        return try mutationOutput(
          RepositoryCollaboratorMutationResult(outcome: .cancelled, target: plan.target),
          json: json
        )
      }
    }
    return try mutationOutput(try await dependencies.remove(plan), json: json)
  }

  private func mutationOutput(
    _ result: RepositoryCollaboratorMutationResult,
    json: Bool
  ) throws -> CLICommandOutput {
    CLICommandOutput(
      stdout: try json
        ? formatter.json(RepositoryJSONEnvelope(result: result))
        : format(result),
      exitCode: result.outcome == .outcomeUnknown ? .api : nil
    )
  }

  private func format(_ collaborators: [RepositoryCollaborator]) -> String {
    formatter.table(
      headers: ["COLLABORATOR", "ADDED BY", "CREATED"],
      rows: collaborators.map { [$0.subjectDID, $0.addedByDID, $0.createdAt.rawValue] }
    )
  }

  private func format(_ result: RepositoryCollaboratorMutationResult) -> String {
    var output = formatter.details([
      ("Outcome", result.outcome.rawValue),
      ("Repository", result.target.repositoryName),
      ("Repository DID", result.target.repositoryDID),
      ("Owner", result.target.ownerDID),
      ("Knot", result.target.knot),
      ("Collaborator", result.target.collaboratorDID),
      ("Error", result.error),
    ])
    if result.outcome == .outcomeUnknown {
      output += "Do not rerun the collaborator mutation automatically; inspect the Knot state first.\n"
    }
    return output
  }
}

private func collaboratorStandardInputIsTerminal() -> Bool {
  #if canImport(Darwin)
    Darwin.isatty(FileHandle.standardInput.fileDescriptor) == 1
  #elseif canImport(Glibc)
    Glibc.isatty(FileHandle.standardInput.fileDescriptor) == 1
  #else
    false
  #endif
}

private func promptForCollaboratorRemoval(_ target: RepositoryCollaboratorTarget) -> Bool {
  let prompt = """
    Remove this repository collaborator?
      Repository: \(target.repositoryName)
      Repository DID: \(target.repositoryDID)
      Knot: \(target.knot)
      Collaborator: \(target.collaboratorDID)
    Continue? [y/N]
    """
  FileHandle.standardError.write(Data(prompt.utf8))
  guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
    return false
  }
  return response.lowercased() == "y" || response.lowercased() == "yes"
}
