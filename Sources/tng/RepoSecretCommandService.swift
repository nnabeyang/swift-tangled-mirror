import ArgumentParser
import Foundation
import SwiftTangled

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct RepoSecretCommandDependencies: Sendable {
  let list: @Sendable (String, String?) async throws -> RepositorySecretList
  let prepareAddition: @Sendable (String, String?, String) async throws -> RepositorySecretAdditionPlan
  let readSecret: @Sendable () throws -> String
  let add:
    @Sendable (RepositorySecretAdditionPlan, String) async throws
      -> RepositorySecretMutationResult
  let prepareRemoval: @Sendable (String, String?, String) async throws -> RepositorySecretRemovalPlan
  let remove: @Sendable (RepositorySecretRemovalPlan) async throws -> RepositorySecretMutationResult
  let originURL: @Sendable () throws -> String
  let inputIsTerminal: @Sendable () -> Bool
  let confirmRemoval: @Sendable (RepositorySecretTarget) -> Bool

  static let live: RepoSecretCommandDependencies = {
    let service = RepositorySecretService()
    return RepoSecretCommandDependencies(
      list: { repository, spindle in
        try await service.secrets(
          repository: repository,
          spindle: spindle,
          pdsClient: try await CLIAuthenticatedClient.make()
        )
      },
      prepareAddition: { repository, spindle, key in
        try await service.prepareAddition(
          repository: repository,
          spindle: spindle,
          key: key,
          pdsClient: try await CLIAuthenticatedClient.make()
        )
      },
      readSecret: { try CLISecretReader().read() },
      add: { plan, value in
        try await service.add(
          plan,
          value: value,
          pdsClient: try await CLIAuthenticatedClient.make()
        )
      },
      prepareRemoval: { repository, spindle, key in
        try await service.prepareRemoval(
          repository: repository,
          spindle: spindle,
          key: key,
          pdsClient: try await CLIAuthenticatedClient.make()
        )
      },
      remove: { plan in
        try await service.remove(
          plan,
          pdsClient: try await CLIAuthenticatedClient.make()
        )
      },
      originURL: { try GitOriginReader().read() },
      inputIsTerminal: { secretCommandStandardInputIsTerminal() },
      confirmRemoval: { promptForSecretRemoval($0) }
    )
  }()
}

struct RepoSecretCommandService: Sendable {
  private let dependencies: RepoSecretCommandDependencies
  private let formatter: CLIFormatter

  init(
    dependencies: RepoSecretCommandDependencies = .live,
    formatter: CLIFormatter = .plain
  ) {
    self.dependencies = dependencies
    self.formatter = formatter
  }

  func list(
    repository: String?,
    spindle: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let result = try await dependencies.list(
      try repository ?? dependencies.originURL(),
      spindle
    )
    return CLICommandOutput(stdout: try json ? formatter.json(result) : format(result.secrets))
  }

  func add(
    repository: String,
    spindle: String?,
    key: String,
    json: Bool
  ) async throws -> CLICommandOutput {
    let plan = try await dependencies.prepareAddition(repository, spindle, key)
    guard !plan.isPresent else {
      return try mutationOutput(
        RepositorySecretMutationResult(outcome: .alreadyPresent, target: plan.target),
        json: json
      )
    }
    return try mutationOutput(
      try await dependencies.add(plan, dependencies.readSecret()),
      json: json
    )
  }

  func remove(
    repository: String,
    spindle: String?,
    key: String,
    confirmed: Bool,
    json: Bool
  ) async throws -> CLICommandOutput {
    let plan = try await dependencies.prepareRemoval(repository, spindle, key)
    guard plan.isPresent else {
      return try mutationOutput(
        RepositorySecretMutationResult(outcome: .notPresent, target: plan.target),
        json: json
      )
    }
    if !confirmed {
      guard dependencies.inputIsTerminal() else {
        throw ValidationError("--yes is required when standard input is not a terminal")
      }
      guard dependencies.confirmRemoval(plan.target) else {
        return try mutationOutput(
          RepositorySecretMutationResult(outcome: .cancelled, target: plan.target),
          json: json
        )
      }
    }
    return try mutationOutput(try await dependencies.remove(plan), json: json)
  }

  private func mutationOutput(
    _ result: RepositorySecretMutationResult,
    json: Bool
  ) throws -> CLICommandOutput {
    CLICommandOutput(
      stdout: try json
        ? formatter.json(RepositoryJSONEnvelope(result: result))
        : format(result),
      exitCode: result.outcome == .outcomeUnknown ? .api : nil
    )
  }

  private func format(_ secrets: [RepositorySecret]) -> String {
    formatter.table(
      headers: ["KEY", "CREATED BY", "CREATED"],
      rows: secrets.map { [$0.key, $0.createdByDID, $0.createdAt.rawValue] }
    )
  }

  private func format(_ result: RepositorySecretMutationResult) -> String {
    var output = formatter.details([
      ("Outcome", result.outcome.rawValue),
      ("Repository", result.target.repositoryName),
      ("Repository URI", result.target.repositoryURI),
      ("Spindle", result.target.spindle),
      ("Key", result.target.key),
    ])
    if result.outcome == .outcomeUnknown {
      output += "Do not rerun the secret mutation automatically; inspect the Spindle state first.\n"
    }
    return output
  }
}

private func secretCommandStandardInputIsTerminal() -> Bool {
  #if canImport(Darwin)
    Darwin.isatty(FileHandle.standardInput.fileDescriptor) == 1
  #elseif canImport(Glibc)
    Glibc.isatty(FileHandle.standardInput.fileDescriptor) == 1
  #else
    false
  #endif
}

private func promptForSecretRemoval(_ target: RepositorySecretTarget) -> Bool {
  let prompt = """
    Remove this repository CI secret?
      Repository: \(target.repositoryName)
      Repository URI: \(target.repositoryURI)
      Spindle: \(target.spindle)
      Key: \(target.key)
    Continue? [y/N]
    """
  FileHandle.standardError.write(Data(prompt.utf8))
  guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
    return false
  }
  return response.lowercased() == "y" || response.lowercased() == "yes"
}
