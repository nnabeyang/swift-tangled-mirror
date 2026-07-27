import Foundation

struct PreparedPullRequest: Sendable {
  let base: String
  let head: String
  let sourceRevision: String
  let title: String
  let body: String?
  let patch: Data
}

struct GitPullRequestPreparer: Sendable {
  private let runCommand: @Sendable ([String]) throws -> Data

  init(
    runCommand: @escaping @Sendable ([String]) throws -> Data = GitPullRequestPreparer.runGit
  ) {
    self.runCommand = runCommand
  }

  func prepare(
    base: String,
    head requestedHead: String?,
    baseRemote: String = "origin"
  ) throws -> PreparedPullRequest {
    let head = try requestedHead ?? text(["symbolic-ref", "--quiet", "--short", "HEAD"])
    guard baseRemote != "origin" || base != head else {
      throw CLICommandError.git("base and head branches must differ")
    }

    let localHead = try text(["rev-parse", "--verify", "refs/heads/\(head)"])
    let remoteHead = try remoteHash(remote: "origin", branch: head)
    guard localHead == remoteHead else {
      throw CLICommandError.git(
        "branch '\(head)' is not pushed at its current commit; run 'git push origin \(head)'"
      )
    }

    let remoteBase = try remoteHash(remote: baseRemote, branch: base)
    do {
      _ = try data(["cat-file", "-e", "\(remoteBase)^{commit}"])
    } catch {
      throw CLICommandError.git(
        "the target base commit is not available locally; run 'git fetch \(baseRemote) \(base)'"
      )
    }

    let range = "\(remoteBase)..\(localHead)"
    let metadata = try data(["log", "--reverse", "--format=%s%x00%b%x00", range])
    let fields = String(decoding: metadata, as: UTF8.self)
      .split(separator: "\0", omittingEmptySubsequences: false)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let title = fields.first, !title.isEmpty else {
      throw CLICommandError.git("base and head do not contain any commits to submit")
    }
    let patch = try data(["format-patch", "--stdout", "--binary", range])
    guard !patch.isEmpty else {
      throw CLICommandError.git("base and head do not contain any commits to submit")
    }
    return PreparedPullRequest(
      base: base,
      head: head,
      sourceRevision: localHead,
      title: title,
      body: fields.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 },
      patch: patch
    )
  }

  private func remoteHash(remote: String, branch: String) throws -> String {
    let output = try text(["ls-remote", "--heads", remote, "refs/heads/\(branch)"])
    guard let hash = output.split(whereSeparator: \.isWhitespace).first else {
      throw CLICommandError.git("branch '\(branch)' does not exist on \(remote)")
    }
    return String(hash)
  }

  private func text(_ arguments: [String]) throws -> String {
    String(decoding: try data(arguments), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func data(_ arguments: [String]) throws -> Data {
    try runCommand(arguments)
  }

  private static func runGit(_ arguments: [String]) throws -> Data {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = standardOutput
    process.standardError = standardError
    do {
      try process.run()
    } catch {
      throw CLICommandError.git("unable to run Git: \(error.localizedDescription)")
    }
    let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
      let message = String(decoding: errorData.isEmpty ? data : errorData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw CLICommandError.git(message.isEmpty ? "Git command failed" : message)
    }
    return data
  }
}
