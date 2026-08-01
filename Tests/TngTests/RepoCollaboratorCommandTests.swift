import ArgumentParser
import Foundation
import SwiftAtproto
import SwiftTangled
import Testing

@testable import tng

@Suite struct RepoCollaboratorCommandTests {
  @Test func parsesListAddAndRemoveCommands() throws {
    let list = try RepoCollaboratorListCommand.parse([
      "alice.example/core", "--limit", "25", "--cursor", "next", "--sort", "asc",
      "--json",
    ])
    #expect(list.repository == "alice.example/core")
    #expect(list.limit == 25)
    #expect(list.cursor == "next")
    #expect(list.sort == "asc")
    #expect(list.json)
    #expect(try RepoCollaboratorListCommand.parse([]).repository == nil)
    #expect(throws: (any Error).self) {
      _ = try RepoCollaboratorListCommand.parse(["--limit", "0"])
    }
    #expect(throws: (any Error).self) {
      _ = try RepoCollaboratorListCommand.parse(["--sort", "newest"])
    }

    let add = try RepoCollaboratorAddCommand.parse([
      "alice.example/core", "@bob.example", "--json",
    ])
    #expect(add.repository == "alice.example/core")
    #expect(add.collaborator == "@bob.example")
    #expect(add.json)

    let remove = try RepoCollaboratorRemoveCommand.parse([
      "alice.example/core", "did:plc:bob", "--yes", "--json",
    ])
    #expect(remove.repository == "alice.example/core")
    #expect(remove.collaborator == "did:plc:bob")
    #expect(remove.yes)
    #expect(remove.json)
  }

  @Test func listUsesOriginAndFormatsPageAndCursor() async throws {
    let recorder = CollaboratorCommandRecorder()
    let service = RepoCollaboratorCommandService(
      dependencies: dependencies(recorder: recorder),
      formatter: .plain
    )
    let human = try await service.list(
      repository: nil,
      cursor: "previous",
      limit: 10,
      sort: .ascending,
      json: false
    )
    #expect(human.stdout.contains("did:plc:collaborator"))
    #expect(human.stderr == "Next cursor: next-page\n")
    #expect(await recorder.listReferences() == ["origin-reference"])

    let json = try await service.list(
      repository: "alice.example/core",
      cursor: nil,
      limit: 30,
      sort: .descending,
      json: true
    )
    let page = try JSONDecoder().decode(
      Page<RepositoryCollaborator>.self,
      from: Data(json.stdout.utf8)
    )
    #expect(page.items.first?.addedByDID == "did:plc:owner")
    #expect(page.cursor == "next-page")
    #expect(json.stderr.isEmpty)
  }

  @Test func addFormatsVersionedResultAndUnknownUsesAPIExit() async throws {
    let target = collaboratorTarget()
    let addedService = RepoCollaboratorCommandService(
      dependencies: dependencies(
        recorder: CollaboratorCommandRecorder(),
        addResult: RepositoryCollaboratorMutationResult(outcome: .added, target: target)
      )
    )
    let added = try await addedService.add(
      repository: "alice.example/core",
      collaborator: "bob.example",
      json: true
    )
    let envelope = try JSONDecoder().decode(
      RepositoryJSONEnvelope<RepositoryCollaboratorMutationResult>.self,
      from: Data(added.stdout.utf8)
    )
    #expect(envelope.schemaVersion == 1)
    #expect(envelope.result.outcome == .added)

    let unknownService = RepoCollaboratorCommandService(
      dependencies: dependencies(
        recorder: CollaboratorCommandRecorder(),
        addResult: RepositoryCollaboratorMutationResult(
          outcome: .outcomeUnknown,
          target: target,
          error: "timeout"
        )
      )
    )
    let unknown = try await unknownService.add(
      repository: "alice.example/core",
      collaborator: "bob.example",
      json: false
    )
    #expect(unknown.exitCode == .api)
    #expect(unknown.stdout.contains("Do not rerun"))
  }

  @Test func removeRequiresConfirmationOnlyForPresentCollaborator() async throws {
    let target = collaboratorTarget()
    let nonInteractive = RepoCollaboratorCommandService(
      dependencies: dependencies(
        recorder: CollaboratorCommandRecorder(),
        plan: RepositoryCollaboratorRemovalPlan(target: target, isPresent: true),
        inputIsTerminal: false
      )
    )
    await #expect(throws: ValidationError.self) {
      _ = try await nonInteractive.remove(
        repository: "alice.example/core",
        collaborator: "bob.example",
        confirmed: false,
        json: false
      )
    }

    let recorder = CollaboratorCommandRecorder()
    let cancelled = RepoCollaboratorCommandService(
      dependencies: dependencies(
        recorder: recorder,
        plan: RepositoryCollaboratorRemovalPlan(target: target, isPresent: true),
        inputIsTerminal: true,
        confirmation: false
      )
    )
    let cancelledOutput = try await cancelled.remove(
      repository: "alice.example/core",
      collaborator: "bob.example",
      confirmed: false,
      json: true
    )
    #expect(cancelledOutput.stdout.contains("cancelled"))
    #expect(await recorder.removeCount() == 0)

    let absent = RepoCollaboratorCommandService(
      dependencies: dependencies(
        recorder: recorder,
        plan: RepositoryCollaboratorRemovalPlan(target: target, isPresent: false),
        inputIsTerminal: false
      )
    )
    let absentOutput = try await absent.remove(
      repository: "alice.example/core",
      collaborator: "bob.example",
      confirmed: false,
      json: false
    )
    #expect(absentOutput.stdout.contains("not_present"))
  }

  private func dependencies(
    recorder: CollaboratorCommandRecorder,
    addResult: RepositoryCollaboratorMutationResult? = nil,
    plan: RepositoryCollaboratorRemovalPlan? = nil,
    inputIsTerminal: Bool = true,
    confirmation: Bool = true
  ) -> RepoCollaboratorCommandDependencies {
    let target = collaboratorTarget()
    return RepoCollaboratorCommandDependencies(
      list: { reference, _, _, _ in
        await recorder.recordList(reference)
        return Page(items: [collaborator()], cursor: "next-page")
      },
      add: { _, _ in
        addResult ?? RepositoryCollaboratorMutationResult(outcome: .added, target: target)
      },
      prepareRemoval: { _, _ in
        plan ?? RepositoryCollaboratorRemovalPlan(target: target, isPresent: true)
      },
      remove: { removalPlan in
        await recorder.recordRemove()
        return RepositoryCollaboratorMutationResult(outcome: .removed, target: removalPlan.target)
      },
      originURL: { "origin-reference" },
      inputIsTerminal: { inputIsTerminal },
      confirmRemoval: { _ in confirmation }
    )
  }

  private func collaborator() -> RepositoryCollaborator {
    RepositoryCollaborator(
      subjectDID: "did:plc:collaborator",
      addedByDID: "did:plc:owner",
      createdAt: FormatString(rawValue: "2026-08-01T00:00:00Z")
    )
  }

  private func collaboratorTarget() -> RepositoryCollaboratorTarget {
    RepositoryCollaboratorTarget(
      repositoryURI: "at://did:plc:owner/sh.tangled.repo/core",
      repositoryDID: "did:plc:repository",
      repositoryName: "core",
      ownerDID: "did:plc:owner",
      knot: "knot.example",
      collaboratorDID: "did:plc:collaborator"
    )
  }
}

private actor CollaboratorCommandRecorder {
  private var references: [String] = []
  private var removals = 0

  func recordList(_ reference: String) { references.append(reference) }
  func recordRemove() { removals += 1 }
  func listReferences() -> [String] { references }
  func removeCount() -> Int { removals }
}
