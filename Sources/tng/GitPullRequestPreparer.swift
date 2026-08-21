import Foundation
import Subprocess
import SwiftTangled

struct PreparedPullRequest: Sendable {
  let base: String
  let head: String
  let sourceRevision: String
  let title: String
  let body: String?
  let patch: Data
}

struct PreparedPullRequestStack: Sendable {
  let base: String
  let head: String
  let sourceRevision: String
  let commits: [PullRequestStackCommit]
}

struct GitPullRequestPreparer: Sendable {
  private let runCommand: @Sendable ([String]) async throws -> Data

  init(
    runCommand: @escaping @Sendable ([String]) async throws -> Data = GitPullRequestPreparer.runGit
  ) {
    self.runCommand = runCommand
  }

  func prepare(
    base: String,
    head requestedHead: String?,
    baseRemote: String = "origin"
  ) async throws -> PreparedPullRequest {
    let head =
      if let requestedHead { requestedHead } else { try await text(["symbolic-ref", "--quiet", "--short", "HEAD"]) }
    guard baseRemote != "origin" || base != head else {
      throw CLICommandError.git("base and head branches must differ")
    }

    let localHead = try await text(["rev-parse", "--verify", "refs/heads/\(head)"])
    let remoteHead = try await remoteHash(remote: "origin", branch: head)
    guard localHead == remoteHead else {
      throw CLICommandError.git(
        "branch '\(head)' is not pushed at its current commit; run 'git push origin \(head)'"
      )
    }

    let remoteBase = try await remoteHash(remote: baseRemote, branch: base)
    do {
      _ = try await data(["cat-file", "-e", "\(remoteBase)^{commit}"])
    } catch {
      throw CLICommandError.git(
        "the target base commit is not available locally; run 'git fetch \(baseRemote) \(base)'"
      )
    }

    let range = "\(remoteBase)..\(localHead)"
    let metadata = try await data(["log", "--reverse", "--format=%s%x00%b%x00", range])
    let fields = String(decoding: metadata, as: UTF8.self)
      .split(separator: "\0", omittingEmptySubsequences: false)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let title = fields.first, !title.isEmpty else {
      throw CLICommandError.git("base and head do not contain any commits to submit")
    }
    let patch = try await data(["format-patch", "--stdout", "--binary", range])
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

  func prepareStack(
    base: String,
    head requestedHead: String?,
    baseRemote: String = "origin"
  ) async throws -> PreparedPullRequestStack {
    let head =
      if let requestedHead { requestedHead } else { try await text(["symbolic-ref", "--quiet", "--short", "HEAD"]) }
    guard baseRemote != "origin" || base != head else {
      throw CLICommandError.git("base and head branches must differ")
    }

    let localHead = try await text(["rev-parse", "--verify", "refs/heads/\(head)"])
    let remoteHead = try await remoteHash(remote: "origin", branch: head)
    guard localHead == remoteHead else {
      throw CLICommandError.git(
        "branch '\(head)' is not pushed at its current commit; run 'git push origin \(head)'"
      )
    }

    let remoteBase = try await remoteHash(remote: baseRemote, branch: base)
    do {
      _ = try await data(["cat-file", "-e", "\(remoteBase)^{commit}"])
    } catch {
      throw CLICommandError.git(
        "the target base commit is not available locally; run 'git fetch \(baseRemote) \(base)'"
      )
    }

    let range = "\(remoteBase)..\(localHead)"
    let metadata = try stackMetadata(
      try await data(["log", "-z", "--reverse", "--format=%H%x00%s%x00%b", range])
    )
    guard !metadata.isEmpty else {
      throw CLICommandError.git("base and head do not contain any commits to submit")
    }
    var seenChangeIDs = Set<String>()
    var commits: [PullRequestStackCommit] = []
    for metadata in metadata {
      let changeID = try commitChangeID(
        try await data(["cat-file", "commit", metadata.revision])
      )
      guard seenChangeIDs.insert(changeID).inserted else {
        throw CLICommandError.git(
          "stacked pull requests require a unique Change-Id header in every commit"
        )
      }
      let patches = try splitFormatPatch(
        try await data([
          "format-patch", "--stdout", "--binary", "--no-cover-letter", "-1",
          metadata.revision, "--add-header", "Change-Id: \(changeID)",
        ])
      )
      guard patches.count == 1, let patch = patches.first else {
        throw CLICommandError.git(
          "git format-patch did not produce exactly one patch for \(metadata.revision)"
        )
      }
      guard metadata.revision == patch.revision else {
        throw CLICommandError.git(
          "git format-patch order does not match the commits in the selected range"
        )
      }
      commits.append(
        PullRequestStackCommit(
          title: metadata.title,
          body: metadata.body,
          changeID: changeID,
          patch: patch.data
        )
      )
    }
    return PreparedPullRequestStack(
      base: base,
      head: head,
      sourceRevision: localHead,
      commits: commits
    )
  }

  private func remoteHash(remote: String, branch: String) async throws -> String {
    let output = try await text(["ls-remote", "--heads", remote, "refs/heads/\(branch)"])
    guard let hash = output.split(whereSeparator: \.isWhitespace).first else {
      throw CLICommandError.git("branch '\(branch)' does not exist on \(remote)")
    }
    return String(hash)
  }

  private func text(_ arguments: [String]) async throws -> String {
    String(decoding: try await data(arguments), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func data(_ arguments: [String]) async throws -> Data {
    try await runCommand(arguments)
  }

  private func stackMetadata(_ data: Data) throws -> [StackCommitMetadata] {
    let fields = String(decoding: data, as: UTF8.self)
      .split(separator: "\0", omittingEmptySubsequences: false)
      .map(String.init)
    let values = fields.last?.isEmpty == true ? Array(fields.dropLast()) : fields
    guard values.count.isMultiple(of: 3) else {
      throw CLICommandError.git("unable to parse commit metadata for pull request stack")
    }
    return try stride(from: 0, to: values.count, by: 3).map { index in
      let revision = values[index].trimmingCharacters(in: .whitespacesAndNewlines)
      let title = values[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
      let body = values[index + 2].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !revision.isEmpty, !title.isEmpty else {
        throw CLICommandError.git("stacked pull request commit metadata is incomplete")
      }
      return StackCommitMetadata(
        revision: revision,
        title: title,
        body: body.isEmpty ? nil : body
      )
    }
  }

  private func splitFormatPatch(_ data: Data) throws -> [StackFormatPatch] {
    guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
      throw CLICommandError.git("git format-patch did not produce valid UTF-8")
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var chunks: [[String]] = []
    for line in lines {
      if formatPatchRevision(line) != nil {
        chunks.append([])
      }
      guard !chunks.isEmpty else {
        guard line.isEmpty else {
          throw CLICommandError.git("git format-patch produced an invalid series")
        }
        continue
      }
      chunks[chunks.index(before: chunks.endIndex)].append(line)
    }
    return try chunks.map { lines in
      guard let first = lines.first, let revision = formatPatchRevision(first) else {
        throw CLICommandError.git("git format-patch produced an invalid patch envelope")
      }
      var patch = lines.joined(separator: "\n")
      if text.hasSuffix("\n"), !patch.hasSuffix("\n") {
        patch.append("\n")
      }
      return StackFormatPatch(
        revision: revision,
        data: Data(patch.utf8)
      )
    }
  }

  private func commitChangeID(_ data: Data) throws -> String {
    let lines = String(decoding: data, as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: false)
    var changeIDs: [String] = []
    for line in lines {
      if line.isEmpty { break }
      let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count == 2, parts[0].caseInsensitiveCompare("change-id") == .orderedSame {
        let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
          changeIDs.append(value)
        }
      }
    }
    guard changeIDs.count == 1 else {
      throw CLICommandError.git(
        "stacked pull requests require exactly one Change-Id header in every commit"
      )
    }
    return changeIDs[0]
  }

  private func formatPatchRevision(_ line: String) -> String? {
    let prefix = "From "
    let suffix = " Mon Sep 17 00:00:00 2001"
    guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
    let revision = line.dropFirst(prefix.count).dropLast(suffix.count)
    guard revision.count == 40 || revision.count == 64, revision.allSatisfy(\.isHexDigit)
    else {
      return nil
    }
    return String(revision)
  }

  private static func runGit(_ arguments: [String]) async throws -> Data {
    let result: ExecutionResult<Void, DataOutput, DataOutput>
    do {
      result = try await Subprocess.run(
        CLISubprocess.executable("/usr/bin/git"),
        arguments: Arguments(arguments),
        platformOptions: CLISubprocess.platformOptions,
        output: .data(limit: CLISubprocess.patchOutputLimit),
        error: .data(limit: CLISubprocess.textOutputLimit)
      )
    } catch {
      throw CLICommandError.git("unable to run Git: \(error)")
    }
    let data = result.standardOutput
    guard result.terminationStatus.isSuccess else {
      let errorData = result.standardError
      let message = String(decoding: errorData.isEmpty ? data : errorData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw CLICommandError.git(message.isEmpty ? "Git command failed" : message)
    }
    return data
  }
}

private struct StackCommitMetadata {
  let revision: String
  let title: String
  let body: String?
}

private struct StackFormatPatch {
  let revision: String
  let data: Data
}
