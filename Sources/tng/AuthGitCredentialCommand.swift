import ArgumentParser
import Foundation
import SwiftTangled

struct AuthGitCredentialCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "git-credential",
    abstract: "Provide credentials to Git",
    shouldDisplay: false
  )

  @Argument var operation: String

  func run() async throws {
    guard operation == "get" else { return }
    do {
      guard let accountIdentifier = CLIAccountOverride.identifier else {
        throw CLICommandError.authentication("Git credential account is not pinned")
      }
      guard ProcessInfo.processInfo.environment["TNG_AUTH_AGENT"] == nil,
        ProcessInfo.processInfo.environment["TNG_SESSION_FILE"] == nil
      else {
        throw CLICommandError.authentication("Git credentials require the account registry")
      }
      let input = try FileHandle.standardInput.readToEnd() ?? Data()
      let request = parseGitCredentialRequest(String(decoding: input, as: UTF8.self))
      let configured = try CLISessionStore.make(account: accountIdentifier)
      guard let account = configured.account, configured.registry != nil else {
        throw CLICommandError.authentication("Git credential account is unavailable")
      }
      let url = try localGitValue("tng.gitURL")
      let target = try await GitAuthenticationService().target(for: url)
      guard target.url == url else {
        throw CLICommandError.git("configured Git authentication target no longer matches Tangled")
      }
      let credential = try await GitAuthenticationService().credential(
        for: request,
        target: target,
        accountHandle: account.handle,
        pdsClient: try PDSClient.restore(from: configured.store)
      )
      print("username=\(credential.username)")
      print("password=\(credential.password)\n")
    } catch {
      print("quit=true\n")
    }
  }
}

func parseGitCredentialRequest(_ input: String) -> GitCredentialRequest {
  var values: [String: String] = [:]
  for line in input.split(whereSeparator: \.isNewline) {
    let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
  }
  return GitCredentialRequest(
    protocolName: values["protocol"], host: values["host"], path: values["path"])
}

private func localGitValue(_ key: String) throws -> String {
  let result = try GitCommandRunner.live.run(["config", "--local", "--get", key])
  let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  guard result.status == 0, !value.isEmpty else {
    throw CLICommandError.git("Git authentication is not configured for this repository")
  }
  return value
}
