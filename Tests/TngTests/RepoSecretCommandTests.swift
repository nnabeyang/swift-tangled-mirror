import ArgumentParser
import Foundation
import SwiftAtproto
import SwiftTangled
import Testing

@testable import tng

@Suite struct RepoSecretCommandTests {
  @Test func parsesListAddAndRemoveCommands() throws {
    let list = try RepoSecretListCommand.parse([
      "alice.example/core", "--spindle", "spindle.example", "--json",
    ])
    #expect(list.repository == "alice.example/core")
    #expect(list.spindle == "spindle.example")
    #expect(list.json)
    #expect(try RepoSecretListCommand.parse([]).repository == nil)

    let add = try RepoSecretAddCommand.parse([
      "alice.example/core", "TOKEN", "--spindle", "spindle.example", "--json",
    ])
    #expect(add.repository == "alice.example/core")
    #expect(add.key == "TOKEN")
    #expect(add.spindle == "spindle.example")
    #expect(add.json)

    let remove = try RepoSecretRemoveCommand.parse([
      "alice.example/core", "TOKEN", "--spindle", "spindle.example", "--yes", "--json",
    ])
    #expect(remove.repository == "alice.example/core")
    #expect(remove.key == "TOKEN")
    #expect(remove.spindle == "spindle.example")
    #expect(remove.yes)
    #expect(remove.json)
  }

  @Test func listUsesOriginAndOutputsOnlyMetadata() async throws {
    let recorder = SecretCommandRecorder()
    let service = RepoSecretCommandService(dependencies: dependencies(recorder: recorder))

    let human = try await service.list(repository: nil, spindle: nil, json: false)
    #expect(human.stdout.contains("TOKEN"))
    #expect(human.stdout.contains("did:plc:owner"))
    #expect(recorder.listReferences == ["origin-reference"])

    let json = try await service.list(
      repository: "alice.example/core",
      spindle: "spindle.example",
      json: true
    )
    let result = try JSONDecoder().decode(
      RepositorySecretList.self,
      from: Data(json.stdout.utf8)
    )
    #expect(result.secrets.first?.key == "TOKEN")
    #expect(!json.stdout.lowercased().contains("value"))
  }

  @Test func existingAdditionDoesNotReadASecret() async throws {
    let recorder = SecretCommandRecorder()
    let service = RepoSecretCommandService(
      dependencies: dependencies(recorder: recorder, additionPresent: true)
    )

    let output = try await service.add(
      repository: "alice.example/core",
      spindle: nil,
      key: "TOKEN",
      json: true
    )
    let envelope = try JSONDecoder().decode(
      RepositoryJSONEnvelope<RepositorySecretMutationResult>.self,
      from: Data(output.stdout.utf8)
    )
    #expect(envelope.result.outcome == .alreadyPresent)
    #expect(recorder.secretReadCount == 0)
    #expect(recorder.addCount == 0)
  }

  @Test func additionNeverIncludesSecretInHumanOrJSONOutput() async throws {
    let recorder = SecretCommandRecorder()
    let service = RepoSecretCommandService(dependencies: dependencies(recorder: recorder))

    let human = try await service.add(
      repository: "alice.example/core",
      spindle: nil,
      key: "TOKEN",
      json: false
    )
    let json = try await service.add(
      repository: "alice.example/core",
      spindle: nil,
      key: "TOKEN",
      json: true
    )

    #expect(human.stdout.contains("added"))
    #expect(!human.stdout.contains("sentinel-secret"))
    #expect(!json.stdout.contains("sentinel-secret"))
    #expect(!json.stdout.lowercased().contains("value"))
    #expect(recorder.secretReadCount == 2)
    #expect(recorder.addCount == 2)
    #expect(recorder.lastSecretByteCount == 15)
  }

  @Test func removalRequiresConfirmationOnlyWhenPresent() async throws {
    let recorder = SecretCommandRecorder()
    let nonInteractive = RepoSecretCommandService(
      dependencies: dependencies(recorder: recorder, inputIsTerminal: false)
    )
    await #expect(throws: ValidationError.self) {
      _ = try await nonInteractive.remove(
        repository: "alice.example/core",
        spindle: nil,
        key: "TOKEN",
        confirmed: false,
        json: false
      )
    }

    let cancelled = RepoSecretCommandService(
      dependencies: dependencies(recorder: recorder, confirmation: false)
    )
    let cancelledOutput = try await cancelled.remove(
      repository: "alice.example/core",
      spindle: nil,
      key: "TOKEN",
      confirmed: false,
      json: true
    )
    #expect(cancelledOutput.stdout.contains("cancelled"))
    #expect(recorder.removeCount == 0)

    let absent = RepoSecretCommandService(
      dependencies: dependencies(recorder: recorder, removalPresent: false, inputIsTerminal: false)
    )
    let absentOutput = try await absent.remove(
      repository: "alice.example/core",
      spindle: nil,
      key: "TOKEN",
      confirmed: false,
      json: false
    )
    #expect(absentOutput.stdout.contains("not_present"))
  }

  private func dependencies(
    recorder: SecretCommandRecorder,
    additionPresent: Bool = false,
    removalPresent: Bool = true,
    inputIsTerminal: Bool = true,
    confirmation: Bool = true
  ) -> RepoSecretCommandDependencies {
    let target = secretTarget()
    return RepoSecretCommandDependencies(
      list: { repository, _ in
        recorder.recordList(repository)
        return RepositorySecretList(
          repositoryURI: target.repositoryURI,
          repositoryName: target.repositoryName,
          spindle: target.spindle,
          secrets: [secretMetadataForCommand()]
        )
      },
      prepareAddition: { _, _, _ in
        RepositorySecretAdditionPlan(target: target, isPresent: additionPresent)
      },
      readSecret: {
        recorder.recordSecretRead()
        return "sentinel-secret"
      },
      add: { plan, value in
        recorder.recordAdd(secretByteCount: value.utf8.count)
        return RepositorySecretMutationResult(outcome: .added, target: plan.target)
      },
      prepareRemoval: { _, _, _ in
        RepositorySecretRemovalPlan(target: target, isPresent: removalPresent)
      },
      remove: { plan in
        recorder.recordRemove()
        return RepositorySecretMutationResult(outcome: .removed, target: plan.target)
      },
      originURL: { "origin-reference" },
      inputIsTerminal: { inputIsTerminal },
      confirmRemoval: { _ in confirmation }
    )
  }
}

private func secretTarget() -> RepositorySecretTarget {
  RepositorySecretTarget(
    repositoryURI: "at://did:plc:owner/sh.tangled.repo/core",
    repositoryName: "core",
    spindle: "https://spindle.example",
    key: "TOKEN"
  )
}

private func secretMetadataForCommand() -> RepositorySecret {
  RepositorySecret(
    repositoryURI: "at://did:plc:owner/sh.tangled.repo/core",
    key: "TOKEN",
    createdAt: FormatString(rawValue: "2026-08-01T00:00:00Z"),
    createdByDID: "did:plc:owner"
  )
}

private final class SecretCommandRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedListReferences: [String] = []
  private var storedSecretReadCount = 0
  private var storedAddCount = 0
  private var storedRemoveCount = 0
  private var storedLastSecretByteCount = 0

  var listReferences: [String] { lock.withLock { storedListReferences } }
  var secretReadCount: Int { lock.withLock { storedSecretReadCount } }
  var addCount: Int { lock.withLock { storedAddCount } }
  var removeCount: Int { lock.withLock { storedRemoveCount } }
  var lastSecretByteCount: Int { lock.withLock { storedLastSecretByteCount } }

  func recordList(_ repository: String) {
    lock.withLock { storedListReferences.append(repository) }
  }
  func recordSecretRead() { lock.withLock { storedSecretReadCount += 1 } }
  func recordAdd(secretByteCount: Int) {
    lock.withLock {
      storedAddCount += 1
      storedLastSecretByteCount = secretByteCount
    }
  }
  func recordRemove() { lock.withLock { storedRemoveCount += 1 } }
}
