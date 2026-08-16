import ArgumentParser
import Foundation
import SwiftTangled

struct GitProcessResult: Sendable {
  let status: Int32
  let stdout: String
  let stderr: String
}

struct GitCommandRunner: Sendable {
  let run: @Sendable ([String]) throws -> GitProcessResult

  static let live = GitCommandRunner { arguments in
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.standardOutput = stdout
    process.standardError = stderr
    do { try process.run() } catch {
      throw CLICommandError.git("failed to run git: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    return GitProcessResult(
      status: process.terminationStatus,
      stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
  }
}

struct GitSetupResult: Codable, Equatable, Sendable {
  let changed: Bool
  let dryRun: Bool
  let remote: String
  let previousURL: String
  let url: String
  let accountDID: String
  let accountHandle: String
  let repositoryURI: String
  let repositoryDID: String
}

struct AuthGitCommandDependencies: Sendable {
  let git: GitCommandRunner
  let target: @Sendable (String) async throws -> GitAuthenticationTarget
  let account: @Sendable (String?) throws -> (AccountSession, any SessionStore)
  let verifyPushScope: @Sendable (any SessionStore, String) async throws -> Void

  static let live: AuthGitCommandDependencies = {
    let service = GitAuthenticationService()
    return AuthGitCommandDependencies(
      git: .live,
      target: { try await service.target(for: $0) },
      account: { identifier in
        if ProcessInfo.processInfo.environment["TNG_AUTH_AGENT"] != nil {
          throw CLICommandError.authentication(
            "Git authentication requires the account registry; TNG_AUTH_AGENT is not supported"
          )
        }
        let configured = try CLISessionStore.make(account: identifier)
        guard configured.registry != nil, let account = configured.account else {
          throw CLICommandError.authentication(
            "Git authentication requires a stored account; TNG_SESSION_FILE and TNG_AUTH_AGENT are not supported"
          )
        }
        return (account, configured.store)
      },
      verifyPushScope: { store, knot in
        _ = try await PDSClient.restore(from: store).serviceAuthToken(
          audience: try gitKnotAudience(knot),
          lxm: tangledRepositoryPushMethod
        )
      }
    )
  }()
}

struct AuthGitCommandService: Sendable {
  let dependencies: AuthGitCommandDependencies

  init(dependencies: AuthGitCommandDependencies = .live) {
    self.dependencies = dependencies
  }

  func setup(
    remote: String,
    dryRun: Bool,
    replaceExistingHelper: Bool,
    explicitAccount: String?
  ) async throws -> GitSetupResult {
    guard !remote.isEmpty else { throw ValidationError("remote must not be empty") }
    let fetchURLs = try gitLines(["remote", "get-url", "--all", remote])
    let pushURLs = try gitLines(["remote", "get-url", "--push", "--all", remote])
    guard fetchURLs.count == 1, pushURLs.count == 1 else {
      throw CLICommandError.git("remote '\(remote)' must have exactly one fetch URL and one push URL")
    }
    guard fetchURLs[0] == pushURLs[0] else {
      throw CLICommandError.git("remote '\(remote)' uses different fetch and push URLs")
    }

    let target = try await dependencies.target(fetchURLs[0])
    let configuredDID = try optionalGitValue(["config", "--local", "--get", "tng.gitAccount"])
    let (account, store) = try dependencies.account(explicitAccount ?? configuredDID)
    try await dependencies.verifyPushScope(store, target.knot)

    let credentialKey = try credentialHelperKey(target)
    let usePathKey = try credentialUseHttpPathKey(target.url)
    let helper = "!tng --account \(account.did) auth git-credential"
    let existingHelpers = try optionalGitLines(["config", "--local", "--get-all", credentialKey])
    let expectedHelpers = ["", helper]
    if !existingHelpers.isEmpty, existingHelpers != expectedHelpers, !replaceExistingHelper {
      throw CLICommandError.git(
        "a different local credential helper is configured for \(target.url); pass --replace-existing-helper to replace it"
      )
    }
    let currentUsePath = try optionalGitValue(["config", "--local", "--get", usePathKey])
    let currentRemote = try optionalGitValue(["config", "--local", "--get", "tng.gitRemote"])
    let currentURL = try optionalGitValue(["config", "--local", "--get", "tng.gitURL"])
    let changed =
      fetchURLs[0] != target.url || existingHelpers != expectedHelpers
      || currentUsePath != "true" || configuredDID != account.did || currentRemote != remote
      || currentURL != target.url

    let result = GitSetupResult(
      changed: changed,
      dryRun: dryRun,
      remote: remote,
      previousURL: fetchURLs[0],
      url: target.url,
      accountDID: account.did,
      accountHandle: account.handle,
      repositoryURI: target.repositoryURI,
      repositoryDID: target.repositoryDID
    )
    guard !dryRun, changed else { return result }

    do {
      try git(["remote", "set-url", remote, target.url])
      try gitAllowMissing(["config", "--local", "--unset-all", credentialKey])
      try git(["config", "--local", "--add", credentialKey, ""])
      try git(["config", "--local", "--add", credentialKey, helper])
      try git(["config", "--local", usePathKey, "true"])
      try git(["config", "--local", "tng.gitAccount", account.did])
      try git(["config", "--local", "tng.gitRemote", remote])
      try git(["config", "--local", "tng.gitURL", target.url])
    } catch {
      try? restore(remote: remote, url: fetchURLs[0], key: credentialKey, values: existingHelpers)
      try? restoreConfig(key: usePathKey, values: currentUsePath.map { [$0] } ?? [])
      try? restoreConfig(key: "tng.gitAccount", values: configuredDID.map { [$0] } ?? [])
      try? restoreConfig(key: "tng.gitRemote", values: currentRemote.map { [$0] } ?? [])
      try? restoreConfig(key: "tng.gitURL", values: currentURL.map { [$0] } ?? [])
      throw error
    }
    return result
  }

  private func restore(remote: String, url: String, key: String, values: [String]) throws {
    try git(["remote", "set-url", remote, url])
    try restoreConfig(key: key, values: values)
  }

  private func restoreConfig(key: String, values: [String]) throws {
    try gitAllowMissing(["config", "--local", "--unset-all", key])
    for value in values { try git(["config", "--local", "--add", key, value]) }
  }

  private func gitLines(_ arguments: [String]) throws -> [String] {
    let result = try dependencies.git.run(arguments)
    guard result.status == 0 else { throw gitError(result) }
    return result.stdout.split(whereSeparator: \.isNewline).map(String.init)
  }

  private func optionalGitLines(_ arguments: [String]) throws -> [String] {
    let result = try dependencies.git.run(arguments)
    if result.status == 1 { return [] }
    guard result.status == 0 else { throw gitError(result) }
    return result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
      .dropLast(result.stdout.hasSuffix("\n") ? 1 : 0).map(String.init)
  }

  private func optionalGitValue(_ arguments: [String]) throws -> String? {
    try optionalGitLines(arguments).first
  }

  private func git(_ arguments: [String]) throws {
    let result = try dependencies.git.run(arguments)
    guard result.status == 0 else { throw gitError(result) }
  }

  private func gitAllowMissing(_ arguments: [String]) throws {
    let result = try dependencies.git.run(arguments)
    guard result.status == 0 || result.status == 5 else { throw gitError(result) }
  }

  private func gitError(_ result: GitProcessResult) -> CLICommandError {
    .git(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "git command failed")
  }

  private func credentialUseHttpPathKey(_ rawURL: String) throws -> String {
    guard let components = URLComponents(string: rawURL),
      components.scheme?.lowercased() == "https",
      let host = components.host
    else { throw CLICommandError.git("configured Git authentication URL is invalid") }
    let authority = components.port.map { "\(host):\($0)" } ?? host
    return "credential.https://\(authority).useHttpPath"
  }

  private func credentialHelperKey(_ target: GitAuthenticationTarget) throws -> String {
    guard let components = URLComponents(string: target.url),
      components.scheme?.lowercased() == "https",
      let host = components.host,
      let encodedDID = target.repositoryDID.addingPercentEncoding(
        withAllowedCharacters: CharacterSet.alphanumerics.union(
          CharacterSet(charactersIn: "-._~")))
    else { throw CLICommandError.git("configured Git authentication URL is invalid") }
    let authority = components.port.map { "\(host):\($0)" } ?? host
    return "credential.https://\(authority)/\(encodedDID)/.helper"
  }
}

private func gitKnotAudience(_ knot: String) throws -> String {
  let raw = knot.contains("://") ? knot : "https://\(knot)"
  guard let url = URL(string: raw), url.scheme?.lowercased() == "https", let host = url.host,
    url.path.isEmpty || url.path == "/"
  else { throw TangledError.invalidRequest("invalid Knot endpoint: \(knot)") }
  let authority = url.port.map { "\(host):\($0)".replacingOccurrences(of: ":", with: "%3A") } ?? host
  return "did:web:\(authority)"
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
