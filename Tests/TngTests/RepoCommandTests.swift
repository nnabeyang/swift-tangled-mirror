import ArgumentParser
import Foundation
import SwiftAtproto
import SwiftTangled
import Testing

@testable import tng

@Suite struct RepoCommandTests {
  @Test func parsesRepositoryArguments() throws {
    let view = try RepoViewCommand.parse(["alice.example/core", "--json"])
    #expect(view.repository == "alice.example/core")
    #expect(view.json)

    let inferredView = try RepoViewCommand.parse([])
    #expect(inferredView.repository == nil)

    let list = try RepoListCommand.parse([
      "alice.example", "--limit", "25", "--cursor", "next", "--sort", "asc", "--json",
    ])
    #expect(list.owner == "alice.example")
    #expect(list.limit == 25)
    #expect(list.cursor == "next")
    #expect(list.sort == "asc")
    #expect(list.json)

    do {
      _ = try RepoListCommand.parse(["--limit", "0"])
      Issue.record("Expected limit validation failure")
    } catch {
      // Expected.
    }
    #expect(throws: (any Error).self) {
      _ = try RepoListCommand.parse(["--sort", "newest"])
    }

    let star = try RepoStarCommand.parse(["alice.example/core"])
    #expect(star.repository == "alice.example/core")
    #expect(try RepoStarCommand.parse([]).repository == nil)

    let unstar = try RepoUnstarCommand.parse(["did:plc:repository"])
    #expect(unstar.repository == "did:plc:repository")
    #expect(try RepoUnstarCommand.parse([]).repository == nil)

    let tree = try RepoTreeCommand.parse([
      "alice.example/core", "--ref", "release", "--path", "Sources", "--json",
    ])
    #expect(tree.repository == "alice.example/core")
    #expect(tree.ref == "release")
    #expect(tree.path == "Sources")
    #expect(tree.json)

    let log = try RepoLogCommand.parse([
      "alice.example/core", "--ref", "main", "--path", "Sources", "-L", "25",
      "--cursor", "50", "--json",
    ])
    #expect(log.repository == "alice.example/core")
    #expect(log.ref == "main")
    #expect(log.path == "Sources")
    #expect(log.limit == 25)
    #expect(log.cursor == "50")
    #expect(log.json)
    #expect(throws: (any Error).self) {
      _ = try RepoLogCommand.parse(["--limit", "101"])
    }

    let blob = try RepoBlobCommand.parse([
      "README.md", "alice.example/core", "--ref", "main", "--json",
    ])
    #expect(blob.path == "README.md")
    #expect(blob.repository == "alice.example/core")
    #expect(blob.ref == "main")
    #expect(blob.json)
    #expect(try RepoBlobCommand.parse(["README.md"]).repository == nil)

    let languages = try RepoLanguagesCommand.parse([
      "alice.example/core", "--ref", "release", "--json",
    ])
    #expect(languages.repository == "alice.example/core")
    #expect(languages.ref == "release")
    #expect(languages.json)
    #expect(try RepoLanguagesCommand.parse([]).repository == nil)

    let archive = try RepoArchiveCommand.parse([
      "alice.example/core", "--ref", "release", "--format", "zip",
      "--prefix", "core/", "-o", "core.zip", "--force",
    ])
    #expect(archive.repository == "alice.example/core")
    #expect(archive.ref == "release")
    #expect(archive.format == .zip)
    #expect(archive.prefix == "core/")
    #expect(archive.output == "core.zip")
    #expect(archive.force)

    let defaultArchive = try RepoArchiveCommand.parse(["--output", "core.tar.gz"])
    #expect(defaultArchive.repository == nil)
    #expect(defaultArchive.ref == nil)
    #expect(defaultArchive.format == .tarGzip)
    #expect(!defaultArchive.force)
    #expect(throws: (any Error).self) {
      _ = try RepoArchiveCommand.parse(["--format", "tar", "-o", "core.tar"])
    }
    #expect(throws: (any Error).self) {
      _ = try RepoArchiveCommand.parse([])
    }

    let branches = try RepoBranchListCommand.parse([
      "alice.example/core", "-L", "25", "--cursor", "50", "--json",
    ])
    #expect(branches.repository == "alice.example/core")
    #expect(branches.limit == 25)
    #expect(branches.cursor == "50")
    #expect(branches.json)
    #expect(throws: (any Error).self) {
      _ = try RepoBranchListCommand.parse(["--limit", "101"])
    }

    let tags = try RepoTagListCommand.parse([
      "alice.example/core", "--limit", "10", "--cursor", "20", "--json",
    ])
    #expect(tags.repository == "alice.example/core")
    #expect(tags.limit == 10)
    #expect(tags.cursor == "20")
    #expect(tags.json)
    #expect(throws: (any Error).self) {
      _ = try RepoTagListCommand.parse(["--limit", "0"])
    }
  }

  @Test func viewUsesExplicitReferenceAndOriginFallback() async throws {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(
      dependencies: dependencies(
        recorder: recorder,
        originURL: { "git@tangled.org:alice.example/core.git" }
      )
    )

    let human = try await service.view(repository: "did:plc:repository", json: false)
    let json = try await service.view(repository: nil, json: true)

    #expect(human.stdout.contains("Name\tcore"))
    #expect(human.stdout.contains("Repository DID\tdid:plc:repository"))
    let decoded = try JSONDecoder().decode(
      TangledRecord<Repository>.self,
      from: Data(json.stdout.utf8)
    )
    #expect(decoded.value.name == "core")
    #expect(
      await recorder.references()
        == ["did:plc:repository", "git@tangled.org:alice.example/core.git"]
    )
  }

  @Test func listResolvesOwnerAndPreservesPageJSON() async throws {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(dependencies: dependencies(recorder: recorder))

    let human = try await service.list(
      owner: "alice.example",
      limit: 25,
      cursor: "previous",
      sort: .ascending,
      json: false
    )
    let json = try await service.list(owner: nil, limit: 30, cursor: nil, json: true)

    #expect(human.stdout.hasPrefix("NAME\tREPO DID\tKNOT\tDESCRIPTION\n"))
    #expect(human.stdout.contains("core\tdid:plc:repository\tknot1.tangled.sh\tCore SDK"))
    #expect(human.stderr == "Next cursor: next-page\n")
    #expect(json.stderr.isEmpty)
    let decoded = try JSONDecoder().decode(
      Page<TangledRecord<Repository>>.self,
      from: Data(json.stdout.utf8)
    )
    #expect(decoded.cursor == "next-page")
    #expect(decoded.items.first?.value.name == "core")
    #expect(await recorder.owners() == ["alice.example"])
    #expect(
      await recorder.listCalls()
        == [
          .init(
            ownerDID: "did:plc:resolved-owner",
            cursor: "previous",
            limit: 25,
            order: .ascending
          ),
          .init(
            ownerDID: "did:plc:session",
            cursor: nil,
            limit: 30,
            order: .descending
          ),
        ]
    )
  }

  @Test func missingOwnerAndSessionRequiresAuthentication() async {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(
      dependencies: dependencies(recorder: recorder, sessionDID: { nil })
    )

    do {
      _ = try await service.list(owner: nil, limit: 30, cursor: nil, json: false)
      Issue.record("Expected authenticationRequired")
    } catch let error as CLICommandError {
      #expect(exitCode(for: error) == 4)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func humanOutputSanitizesTableControlCharacters() async throws {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(
      dependencies: dependencies(
        recorder: recorder,
        record: sampleRecord(description: "line one\nline\ttwo")
      )
    )

    let output = try await service.list(owner: "did:plc:owner", limit: 1, cursor: nil, json: false)
    #expect(output.stdout.contains("line one line two"))
  }

  @Test func humanOutputFallsBackToRepositoryRkeyForName() async throws {
    let recorder = RepoCommandRecorder()
    let unnamed = TangledRecord(
      uri: "at://did:plc:owner/sh.tangled.repo/core",
      value: Repository(
        knot: "knot1.tangled.sh",
        createdAt: FormatString<Date>(rawValue: "2026-03-30T09:14:36Z")
      )
    )
    let service = RepoCommandService(
      dependencies: dependencies(recorder: recorder, record: unnamed)
    )

    let view = try await service.view(repository: "alice.example/core", json: false)
    let list = try await service.list(owner: "alice.example", limit: 1, cursor: nil, json: false)

    #expect(view.stdout.contains("Name\tcore"))
    #expect(list.stdout.contains("\ncore\t-\tknot1.tangled.sh\t-\n"))
  }

  @Test func starResolvesRepositoryAndUsesItsRepoDID() async throws {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.star(repository: "alice.example/core")

    #expect(output.stdout == "Starred core (did:plc:repository).\n")
    #expect(await recorder.references() == ["alice.example/core"])
    #expect(await recorder.starredRepositoryDIDs() == ["did:plc:repository"])
  }

  @Test func gitCommandsResolveOriginAndDefaultBranch() async throws {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(
      dependencies: dependencies(
        recorder: recorder,
        originURL: { "git@tangled.org:alice.example/core.git" }
      )
    )

    let tree = try await service.tree(
      repository: nil,
      ref: nil,
      path: "Sources",
      json: false
    )
    let log = try await service.log(
      repository: nil,
      ref: nil,
      path: nil,
      cursor: "2",
      limit: 2,
      json: false
    )

    #expect(tree.stdout.hasPrefix("MODE\tSIZE\tNAME\tLAST COMMIT\tMESSAGE\n"))
    #expect(tree.stdout.contains("0100644\t128\tPackage.swift\taaaaaaa\tUpdate package"))
    #expect(log.stdout.hasPrefix("HASH\tDATE\tAUTHOR\tMESSAGE\n"))
    #expect(log.stdout.contains("bbbbbbb\t2026-07-22T12:00:00Z\tAlice\tAdd feature "))
    #expect(log.stderr == "Next cursor: 4\n")
    #expect(
      await recorder.references()
        == [
          "git@tangled.org:alice.example/core.git",
          "git@tangled.org:alice.example/core.git",
        ]
    )
    #expect(await recorder.defaultBranchURIs() == [sampleRecord().uri, sampleRecord().uri])
    #expect(
      await recorder.gitCalls()
        == [
          .init(
            operation: "tree",
            repositoryURI: sampleRecord().uri,
            ref: "main",
            path: "Sources"
          ),
          .init(
            operation: "log",
            repositoryURI: sampleRecord().uri,
            ref: "main",
            cursor: "2",
            limit: 2
          ),
        ]
    )
  }

  @Test func explicitRefSkipsDefaultBranchAndJSONPreservesModels() async throws {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(dependencies: dependencies(recorder: recorder))

    let tree = try await service.tree(
      repository: "alice.example/core",
      ref: "release",
      path: nil,
      json: true
    )
    let log = try await service.log(
      repository: "alice.example/core",
      ref: "release",
      path: nil,
      cursor: nil,
      limit: 30,
      json: true
    )

    #expect(try JSONDecoder().decode(GitTree.self, from: tree.stdoutData).ref == "release")
    #expect(try JSONDecoder().decode(GitLogPage.self, from: log.stdoutData).total == 5)
    #expect(log.stderr.isEmpty)
    #expect(await recorder.defaultBranchURIs().isEmpty)
  }

  @Test func branchAndTagListsResolveRepositoriesAndFormatPages() async throws {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(
      dependencies: dependencies(
        recorder: recorder,
        originURL: { "git@tangled.org:alice.example/core.git" }
      )
    )

    let branches = try await service.branches(
      repository: nil,
      cursor: "2",
      limit: 2,
      json: false
    )
    let tags = try await service.tags(
      repository: "alice.example/core",
      cursor: "4",
      limit: 2,
      json: false
    )

    #expect(branches.stdout.hasPrefix("NAME\tDEFAULT\tHASH\tUPDATED\tAUTHOR\tMESSAGE\n"))
    #expect(
      branches.stdout.contains(
        "main\tyes\taaaaaaa\t2026-07-22T12:00:00Z\tAlice\tUpdate main "
      )
    )
    #expect(branches.stdout.contains("feature\tno\tbbbbbbb\t-\t-\t-"))
    #expect(branches.stderr == "Next cursor: 4\n")
    #expect(tags.stdout.hasPrefix("NAME\tHASH\tTARGET\tDATE\tTAGGER\tMESSAGE\n"))
    #expect(
      tags.stdout.contains(
        "v1.0.0\tccccccc\tddddddd\t2026-07-22T12:00:00Z\tAlice\tVersion 1.0.0 "
      )
    )
    #expect(tags.stdout.contains("snapshot\teeeeeee\t-\t-\t-\t-"))
    #expect(tags.stderr == "Next cursor: 6\n")
    #expect(
      await recorder.references()
        == ["git@tangled.org:alice.example/core.git", "alice.example/core"]
    )
    #expect(
      await recorder.referenceListCalls()
        == [
          .init(
            operation: "branches",
            repositoryURI: sampleRecord().uri,
            cursor: "2",
            limit: 2
          ),
          .init(
            operation: "tags",
            repositoryURI: sampleRecord().uri,
            cursor: "4",
            limit: 2
          ),
        ]
    )
    #expect(await recorder.defaultBranchURIs().isEmpty)
  }

  @Test func languagesUsesOriginDefaultBranchAndPreservesCompleteJSON() async throws {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(
      dependencies: dependencies(
        recorder: recorder,
        originURL: { "git@tangled.org:alice.example/core.git" }
      )
    )

    let human = try await service.languages(repository: nil, ref: nil, json: false)
    let json = try await service.languages(
      repository: "alice.example/core",
      ref: "release",
      json: true
    )

    #expect(human.stdout.hasPrefix("LANGUAGE\tPERCENT\tBYTES\tFILES\n"))
    #expect(human.stdout.contains("Swift\t80%\t8192\t12"))
    #expect(human.stdout.contains("Other\t20%\t2048\t-"))
    let report = try JSONDecoder().decode(GitLanguageReport.self, from: json.stdoutData)
    #expect(report.ref == "release")
    #expect(report.totalFiles == 14)
    #expect(report.totalSize == 10_240)
    #expect(report.languages.first?.color == "#F05138")
    #expect(report.languages.first?.extensions == [".swift"])
    #expect(
      await recorder.references()
        == ["git@tangled.org:alice.example/core.git", "alice.example/core"]
    )
    #expect(await recorder.defaultBranchURIs() == [sampleRecord().uri])
    #expect(
      await recorder.gitCalls()
        == [
          .init(
            operation: "languages",
            repositoryURI: sampleRecord().uri,
            ref: "main"
          ),
          .init(
            operation: "languages",
            repositoryURI: sampleRecord().uri,
            ref: "release"
          ),
        ]
    )
  }

  @Test func languagesEmptyResultKeepsHumanHeader() async throws {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(
      dependencies: dependencies(
        recorder: recorder,
        languageReport: GitLanguageReport(ref: "main", languages: [])
      )
    )

    let output = try await service.languages(
      repository: "alice.example/core",
      ref: "main",
      json: false
    )

    #expect(output.stdout == "LANGUAGE\tPERCENT\tBYTES\tFILES\n")
  }

  @Test func branchAndTagJSONPreserveCompletePagesWithoutDiagnostics() async throws {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(dependencies: dependencies(recorder: recorder))

    let branches = try await service.branches(
      repository: "alice.example/core",
      cursor: nil,
      limit: 30,
      json: true
    )
    let tags = try await service.tags(
      repository: "alice.example/core",
      cursor: nil,
      limit: 30,
      json: true
    )

    let branchPage = try JSONDecoder().decode(Page<GitBranch>.self, from: branches.stdoutData)
    let tagPage = try JSONDecoder().decode(Page<GitTag>.self, from: tags.stdoutData)
    #expect(branchPage.cursor == "4")
    #expect(branchPage.items.first?.reference.name == "main")
    #expect(tagPage.cursor == "6")
    #expect(tagPage.items.first?.reference.name == "v1.0.0")
    #expect(branches.stderr.isEmpty)
    #expect(tags.stderr.isEmpty)
  }

  @Test func blobPreservesBytesAndHandlesJSONSubmoduleAndLargeFiles() async throws {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(dependencies: dependencies(recorder: recorder))

    let binary = try await service.blob(
      path: "binary.bin",
      repository: nil,
      ref: nil,
      json: false
    )
    let empty = try await service.blob(
      path: "empty.txt",
      repository: nil,
      ref: "main",
      json: false
    )
    let json = try await service.blob(
      path: "binary.bin",
      repository: nil,
      ref: "main",
      json: true
    )
    let submodule = try await service.blob(
      path: "Vendor/Dependency",
      repository: nil,
      ref: "main",
      json: false
    )

    #expect(binary.stdoutData == Data([0x00, 0xFF, 0x0A]))
    #expect(empty.stdoutData.isEmpty)
    #expect(try JSONDecoder().decode(GitBlob.self, from: json.stdoutData).isBinary)
    #expect(submodule.stdout.contains("Submodule\tDependency"))
    #expect(submodule.stdout.contains("URL\thttps://example.com/dependency.git"))

    do {
      _ = try await service.blob(
        path: "large.bin",
        repository: nil,
        ref: "main",
        json: false
      )
      Issue.record("Expected fileTooLarge failure")
    } catch TangledError.invalidRequest(let message) {
      #expect(message == "blob is too large to return: large.bin")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func starUsesExplicitRepoDIDWithoutBobbinLookup() async throws {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.star(repository: "did:plc:repository")

    #expect(output.stdout == "Starred did:plc:repository.\n")
    #expect(await recorder.references().isEmpty)
    #expect(await recorder.starredRepositoryDIDs() == ["did:plc:repository"])
  }

  @Test func starAndUnstarUseOriginFallback() async throws {
    let recorder = RepoCommandRecorder()
    let service = RepoCommandService(
      dependencies: dependencies(
        recorder: recorder,
        originURL: { "git@tangled.org:alice.example/core.git" }
      )
    )

    let starred = try await service.star(repository: nil)
    let unstarred = try await service.unstar(repository: nil)

    #expect(starred.stdout == "Starred core (did:plc:repository).\n")
    #expect(unstarred.stdout == "Unstarred core (did:plc:repository).\n")
    #expect(
      await recorder.references()
        == [
          "git@tangled.org:alice.example/core.git",
          "git@tangled.org:alice.example/core.git",
        ]
    )
    #expect(await recorder.unstarredRepositoryDIDs() == ["did:plc:repository"])
  }

  @Test func unstarReportsAlreadyAbsentRepository() async throws {
    let recorder = RepoCommandRecorder(unstarResult: false)
    let service = RepoCommandService(dependencies: dependencies(recorder: recorder))

    let output = try await service.unstar(repository: "alice.example/core")

    #expect(
      output.stdout == "Repository was not starred: core (did:plc:repository).\n"
    )
  }

  @Test func starRejectsRepositoryWithoutRepoDID() async {
    let recorder = RepoCommandRecorder()
    let record = TangledRecord(
      uri: "at://did:plc:owner/sh.tangled.repo/core",
      value: Repository(
        name: "core",
        knot: "knot1.tangled.sh",
        createdAt: FormatString<Date>(rawValue: "2026-03-30T09:14:36Z")
      )
    )
    let service = RepoCommandService(
      dependencies: dependencies(recorder: recorder, record: record)
    )

    do {
      _ = try await service.star(repository: "alice.example/core")
      Issue.record("Expected missing repo DID failure")
    } catch let TangledError.invalidRequest(message) {
      #expect(message == "repository has no repo DID")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await recorder.starredRepositoryDIDs().isEmpty)
  }

  @Test func archiveUsesExplicitReferenceFormatPrefixAndOutput() async throws {
    let recorder = RepoCommandRecorder()
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("core.zip")
    let service = RepoCommandService(
      dependencies: dependencies(
        recorder: recorder,
        archive: {
          repositoryURI,
          ref,
          format,
          prefix,
          destination in
          await recorder.record(
            archive: .init(
              repositoryURI: repositoryURI,
              ref: ref,
              format: format,
              prefix: prefix,
              destination: destination
            )
          )
          return 2_048
        })
    )

    let result = try await service.archive(
      repository: "alice.example/core",
      ref: "release",
      format: .zip,
      prefix: "core/",
      output: output.path,
      force: false
    )

    #expect(result.stdout == "Saved archive to \(output.path) (2048 bytes).\n")
    #expect(await recorder.references() == ["alice.example/core"])
    #expect(await recorder.defaultBranchURIs().isEmpty)
    #expect(
      await recorder.archiveCalls()
        == [
          RepoArchiveCall(
            repositoryURI: "at://did:plc:owner/sh.tangled.repo/core",
            ref: "release",
            format: .zip,
            prefix: "core/",
            destination: output
          )
        ])
  }

  @Test func archiveUsesOriginAndDefaultBranchWhenOmitted() async throws {
    let recorder = RepoCommandRecorder()
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("core.tar.gz")
    let service = RepoCommandService(
      dependencies: dependencies(
        recorder: recorder,
        originURL: { "git@tangled.org:alice.example/core.git" }
      )
    )

    _ = try await service.archive(
      repository: nil,
      ref: nil,
      format: .tarGzip,
      prefix: nil,
      output: output.path,
      force: false
    )

    #expect(await recorder.references() == ["git@tangled.org:alice.example/core.git"])
    #expect(
      await recorder.defaultBranchURIs()
        == ["at://did:plc:owner/sh.tangled.repo/core"])
    #expect(await recorder.archiveCalls().first?.ref == "main")
    #expect(await recorder.archiveCalls().first?.format == .tarGzip)
  }

  @Test func archiveValidatesOutputBeforeResolvingRepository() async throws {
    let recorder = RepoCommandRecorder()
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let existingFile = directory.appendingPathComponent("existing.zip")
    try Data("old".utf8).write(to: existingFile)
    let missingParent = directory.appendingPathComponent("missing/archive.zip")
    let service = RepoCommandService(dependencies: dependencies(recorder: recorder))

    for output in [existingFile, directory, missingParent] {
      do {
        _ = try await service.archive(
          repository: "alice.example/core",
          ref: "main",
          format: .zip,
          prefix: nil,
          output: output.path,
          force: output == existingFile ? false : true
        )
        Issue.record("Expected invalid output failure for \(output.path)")
      } catch is ValidationError {
        // Expected.
      } catch {
        Issue.record("Unexpected error: \(error)")
      }
    }

    #expect(await recorder.references().isEmpty)
    #expect(await recorder.archiveCalls().isEmpty)
  }

  @Test func archiveForceAllowsReplacingExistingFile() async throws {
    let recorder = RepoCommandRecorder()
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("existing.zip")
    try Data("old".utf8).write(to: output)
    let service = RepoCommandService(
      dependencies: dependencies(
        recorder: recorder,
        archive: {
          _, _, _, _, destination in
          let replacement = Data("replacement".utf8)
          try replacement.write(to: destination)
          return Int64(replacement.count)
        })
    )

    _ = try await service.archive(
      repository: "alice.example/core",
      ref: "main",
      format: .zip,
      prefix: nil,
      output: output.path,
      force: true
    )

    #expect(try Data(contentsOf: output) == Data("replacement".utf8))
  }
}

extension RepoCommandTests {
  fileprivate func dependencies(
    recorder: RepoCommandRecorder,
    record: TangledRecord<Repository>? = nil,
    languageReport: GitLanguageReport? = nil,
    sessionDID: @escaping @Sendable () throws -> String? = { "did:plc:session" },
    originURL: @escaping @Sendable () throws -> String = { "unused" },
    archive: (
      @Sendable (
        String, String, GitArchiveFormat, String?, URL
      ) async throws -> Int64
    )? = nil
  ) -> RepoCommandDependencies {
    let record = record ?? sampleRecord()
    return RepoCommandDependencies(
      resolveRepository: { reference in
        await recorder.record(reference: reference)
        return record
      },
      resolveOwnerDID: { owner in
        await recorder.record(owner: owner)
        return owner.hasPrefix("did:") ? owner : "did:plc:resolved-owner"
      },
      repositories: { ownerDID, cursor, limit, order in
        await recorder.record(
          list: .init(ownerDID: ownerDID, cursor: cursor, limit: limit, order: order)
        )
        return Page(items: [record], cursor: "next-page")
      },
      sessionDID: sessionDID,
      originURL: originURL,
      defaultBranch: { repositoryURI in
        await recorder.record(defaultBranch: repositoryURI)
        return GitDefaultBranch(
          name: "main",
          hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          when: FormatString<Date>(rawValue: "2026-07-22T12:00:00Z")
        )
      },
      tree: { repositoryURI, ref, path in
        await recorder.record(
          git: .init(
            operation: "tree",
            repositoryURI: repositoryURI,
            ref: ref,
            path: path
          )
        )
        return sampleTree(ref: ref)
      },
      log: { repositoryURI, ref, path, cursor, limit in
        await recorder.record(
          git: .init(
            operation: "log",
            repositoryURI: repositoryURI,
            ref: ref,
            path: path,
            cursor: cursor,
            limit: limit
          )
        )
        return sampleLog(ref: ref)
      },
      blob: { repositoryURI, ref, path in
        await recorder.record(
          git: .init(
            operation: "blob",
            repositoryURI: repositoryURI,
            ref: ref,
            path: path
          )
        )
        return sampleBlob(path: path, ref: ref)
      },
      languages: { repositoryURI, ref in
        await recorder.record(
          git: .init(
            operation: "languages",
            repositoryURI: repositoryURI,
            ref: ref
          )
        )
        return languageReport ?? sampleLanguages(ref: ref)
      },
      branches: { repositoryURI, cursor, limit in
        await recorder.record(
          referenceList: .init(
            operation: "branches",
            repositoryURI: repositoryURI,
            cursor: cursor,
            limit: limit
          )
        )
        return sampleBranches()
      },
      tags: { repositoryURI, cursor, limit in
        await recorder.record(
          referenceList: .init(
            operation: "tags",
            repositoryURI: repositoryURI,
            cursor: cursor,
            limit: limit
          )
        )
        return sampleTags()
      },
      archive: archive ?? { repositoryURI, ref, format, prefix, destination in
        await recorder.record(
          archive: .init(
            repositoryURI: repositoryURI,
            ref: ref,
            format: format,
            prefix: prefix,
            destination: destination
          )
        )
        return 0
      },
      star: { repositoryDID in
        await recorder.record(star: repositoryDID)
        return TangledRecord(
          uri: "at://did:plc:session/sh.tangled.feed.star/3jzfcijpj2z2a",
          cid: "bafystar",
          value: Star(
            subject: .repository(did: repositoryDID),
            createdAt: FormatString<Date>(rawValue: "2026-07-22T12:34:56Z")
          )
        )
      },
      unstar: { repositoryDID in
        await recorder.record(unstar: repositoryDID)
        return await recorder.currentUnstarResult()
      }
    )
  }

  fileprivate func sampleRecord(description: String = "Core SDK") -> TangledRecord<Repository> {
    TangledRecord(
      uri: "at://did:plc:owner/sh.tangled.repo/core",
      cid: "bafycore",
      value: Repository(
        name: "core",
        knot: "knot1.tangled.sh",
        description: description,
        topics: ["swift", "atproto"],
        repoDID: "did:plc:repository",
        createdAt: FormatString<Date>(rawValue: "2026-03-30T09:14:36Z")
      )
    )
  }

  fileprivate func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  fileprivate func sampleTree(ref: String) -> GitTree {
    GitTree(
      ref: ref,
      entries: [
        GitTreeEntry(
          name: "Package.swift",
          mode: "0100644",
          size: 128,
          lastCommit: GitLastCommit(
            hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            message: "Update package\n",
            when: FormatString<Date>(rawValue: "2026-07-22T12:00:00Z")
          )
        )
      ]
    )
  }

  fileprivate func sampleLog(ref: String) -> GitLogPage {
    GitLogPage(
      commits: [
        GitCommit(
          hash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          author: GitSignature(
            name: "Alice",
            email: "alice@example.com",
            when: FormatString<Date>(rawValue: "2026-07-22T12:00:00Z")
          ),
          committer: GitSignature(
            name: "Tangled",
            email: "noreply@tangled.org",
            when: FormatString<Date>(rawValue: "2026-07-22T12:01:00Z")
          ),
          message: "Add feature\n",
          tree: "cccccccccccccccccccccccccccccccccccccccc"
        )
      ],
      cursor: "4",
      ref: ref,
      total: 5,
      page: 2
    )
  }

  fileprivate func sampleBlob(path: String, ref: String) -> GitBlob {
    switch path {
    case "binary.bin":
      GitBlob(
        ref: ref,
        path: path,
        content: Data([0x00, 0xFF, 0x0A]),
        encoding: .base64,
        size: 3,
        isBinary: true
      )
    case "Vendor/Dependency":
      GitBlob(
        ref: ref,
        path: path,
        submodule: GitSubmodule(
          name: "Dependency",
          url: "https://example.com/dependency.git",
          branch: "main"
        )
      )
    case "large.bin":
      GitBlob(ref: ref, path: path, size: 10_000_000, isBinary: true, fileTooLarge: true)
    default:
      GitBlob(ref: ref, path: path)
    }
  }

  fileprivate func sampleLanguages(ref: String) -> GitLanguageReport {
    GitLanguageReport(
      ref: ref,
      languages: [
        GitLanguage(
          name: "Swift",
          size: 8192,
          percentage: 80,
          fileCount: 12,
          color: "#F05138",
          extensions: [".swift"]
        ),
        GitLanguage(name: "Other", size: 2048, percentage: 20),
      ],
      totalFiles: 14,
      totalSize: 10_240
    )
  }

  fileprivate func sampleBranches() -> Page<GitBranch> {
    let signature = GitSignature(
      name: "Alice",
      email: "alice@example.com",
      when: FormatString<Date>(rawValue: "2026-07-22T12:00:00Z")
    )
    return Page(
      items: [
        GitBranch(
          reference: GitReference(name: "main", hash: String(repeating: "a", count: 40)),
          commit: GitCommit(
            hash: String(repeating: "a", count: 40),
            author: signature,
            committer: signature,
            message: "Update main\n",
            tree: String(repeating: "f", count: 40)
          ),
          isDefault: true
        ),
        GitBranch(
          reference: GitReference(name: "feature", hash: String(repeating: "b", count: 40))
        ),
      ],
      cursor: "4"
    )
  }

  fileprivate func sampleTags() -> Page<GitTag> {
    Page(
      items: [
        GitTag(
          reference: GitReference(name: "v1.0.0", hash: String(repeating: "c", count: 40)),
          tagger: GitSignature(
            name: "Alice",
            email: "alice@example.com",
            when: FormatString<Date>(rawValue: "2026-07-22T12:00:00Z")
          ),
          message: "Version 1.0.0\n",
          targetHash: String(repeating: "d", count: 40)
        ),
        GitTag(
          reference: GitReference(name: "snapshot", hash: String(repeating: "e", count: 40))
        ),
      ],
      cursor: "6"
    )
  }
}

private struct RepoGitCall: Equatable, Sendable {
  let operation: String
  let repositoryURI: String
  let ref: String
  let path: String?
  let cursor: String?
  let limit: Int?

  init(
    operation: String,
    repositoryURI: String,
    ref: String,
    path: String? = nil,
    cursor: String? = nil,
    limit: Int? = nil
  ) {
    self.operation = operation
    self.repositoryURI = repositoryURI
    self.ref = ref
    self.path = path
    self.cursor = cursor
    self.limit = limit
  }
}

private struct RepoReferenceListCall: Equatable, Sendable {
  let operation: String
  let repositoryURI: String
  let cursor: String?
  let limit: Int
}

private struct RepoArchiveCall: Equatable, Sendable {
  let repositoryURI: String
  let ref: String
  let format: GitArchiveFormat
  let prefix: String?
  let destination: URL
}

private actor RepoCommandRecorder {
  struct ListCall: Equatable, Sendable {
    let ownerDID: String
    let cursor: String?
    let limit: Int
    let order: BobbinSortOrder
  }

  private var recordedReferences: [String] = []
  private var recordedOwners: [String] = []
  private var recordedListCalls: [ListCall] = []
  private var recordedStars: [String] = []
  private var recordedUnstars: [String] = []
  private var recordedDefaultBranchURIs: [String] = []
  private var recordedGitCalls: [RepoGitCall] = []
  private var recordedReferenceListCalls: [RepoReferenceListCall] = []
  private var recordedArchiveCalls: [RepoArchiveCall] = []
  private let unstarResult: Bool

  init(unstarResult: Bool = true) {
    self.unstarResult = unstarResult
  }

  func record(reference: String) {
    recordedReferences.append(reference)
  }

  func record(owner: String) {
    recordedOwners.append(owner)
  }

  func record(list: ListCall) {
    recordedListCalls.append(list)
  }

  func record(star repositoryDID: String) {
    recordedStars.append(repositoryDID)
  }

  func record(unstar repositoryDID: String) {
    recordedUnstars.append(repositoryDID)
  }

  func record(defaultBranch repositoryURI: String) {
    recordedDefaultBranchURIs.append(repositoryURI)
  }

  func record(git call: RepoGitCall) {
    recordedGitCalls.append(call)
  }

  func record(referenceList call: RepoReferenceListCall) {
    recordedReferenceListCalls.append(call)
  }

  func record(archive call: RepoArchiveCall) {
    recordedArchiveCalls.append(call)
  }

  func references() -> [String] {
    recordedReferences
  }

  func owners() -> [String] {
    recordedOwners
  }

  func listCalls() -> [ListCall] {
    recordedListCalls
  }

  func starredRepositoryDIDs() -> [String] {
    recordedStars
  }

  func unstarredRepositoryDIDs() -> [String] {
    recordedUnstars
  }

  func currentUnstarResult() -> Bool {
    unstarResult
  }

  func defaultBranchURIs() -> [String] {
    recordedDefaultBranchURIs
  }

  func gitCalls() -> [RepoGitCall] {
    recordedGitCalls
  }

  func referenceListCalls() -> [RepoReferenceListCall] {
    recordedReferenceListCalls
  }

  func archiveCalls() -> [RepoArchiveCall] {
    recordedArchiveCalls
  }
}
