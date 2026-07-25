import Foundation
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@testable import SwiftTangled

@Suite struct GitContentAPITests {
  private let repositoryURI = "at://did:plc:owner/sh.tangled.repo/example"

  @Test func defaultBranchAndTreeUseGeneratedQueriesAndMapModels() async throws {
    let transport = GitContentTransport([
      .init(statusCode: 200, body: try fixture("git-default-branch")),
      .init(statusCode: 200, body: try fixture("git-tree")),
    ])
    let client = makeClient(transport)

    let branch = try await client.defaultBranch(repositoryURI: repositoryURI)
    let tree = try await client.tree(repositoryURI: repositoryURI, ref: "main", path: "src")

    #expect(branch.name == "main")
    #expect(branch.author?.name == "Alice")
    #expect(tree.entries.count == 2)
    #expect(tree.entries[0].isDirectory)
    #expect(tree.entries[0].lastCommit?.hash == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    #expect(!tree.entries[1].isDirectory)
    #expect(tree.readme?.contents == "# Example\n")

    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.repo.getDefaultBranch")
    #expect(query("repo", requests[0]) == repositoryURI)
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.repo.tree")
    #expect(query("repo", requests[1]) == repositoryURI)
    #expect(query("ref", requests[1]) == "main")
    #expect(query("path", requests[1]) == "src")
  }

  @Test func branchesAndTagsDecodeGitReferencesAndDeriveOffsetCursors() async throws {
    let transport = GitContentTransport([
      .init(statusCode: 200, body: try fixture("git-branches")),
      .init(statusCode: 200, body: try fixture("git-tags")),
    ])
    let client = makeClient(transport)

    let branches = try await client.branches(
      repositoryURI: repositoryURI,
      cursor: "2",
      limit: 2
    )
    let tags = try await client.tags(
      repositoryURI: repositoryURI,
      cursor: "4",
      limit: 2
    )

    #expect(branches.cursor == "4")
    #expect(branches.items[0].reference.name == "main")
    #expect(branches.items[0].isDefault)
    #expect(branches.items[0].commit?.hash == "0102030405060708090a0b0c0d0e0f1011121314")
    #expect(branches.items[0].commit?.tree == "14131211100f0e0d0c0b0a090807060504030201")
    #expect(branches.items[0].commit?.author.name == "Alice")
    #expect(branches.items[1].commit == nil)
    #expect(tags.cursor == "6")
    #expect(tags.items[0].reference.name == "v1.0.0")
    #expect(tags.items[0].tagger?.name == "Alice")
    #expect(tags.items[0].message == "Version 1.0.0\n")
    #expect(tags.items[0].targetHash == "0101010101010101010101010101010101010101")
    #expect(tags.items[1].tagger == nil)
    #expect(tags.items[1].targetHash == nil)

    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.repo.branches")
    #expect(query("repo", requests[0]) == repositoryURI)
    #expect(query("cursor", requests[0]) == "2")
    #expect(query("limit", requests[0]) == "2")
    #expect(requests[1].url?.lastPathComponent == "sh.tangled.repo.tags")
    #expect(query("cursor", requests[1]) == "4")
  }

  @Test func shortGitReferencePagesHaveNoNextCursor() async throws {
    let branches = try JSONSerialization.data(withJSONObject: [
      "branches": [["reference": ["name": "main", "hash": "abc"]]]
    ])
    let tags = try JSONSerialization.data(withJSONObject: ["tags": []])
    let transport = GitContentTransport([
      .init(statusCode: 200, body: branches),
      .init(statusCode: 200, body: tags),
    ])
    let client = makeClient(transport)

    #expect(try await client.branches(repositoryURI: repositoryURI, limit: 2).cursor == nil)
    #expect(try await client.tags(repositoryURI: repositoryURI, limit: 2).cursor == nil)
  }

  @Test func emptyRepositoryTagObjectDecodesAsAnEmptyPage() async throws {
    let transport = GitContentTransport([
      .init(statusCode: 200, body: Data("{}".utf8))
    ])

    let page = try await makeClient(transport).tags(repositoryURI: repositoryURI)

    #expect(page.items.isEmpty)
    #expect(page.cursor == nil)
  }

  @Test func describeRepositorySendsBobbinRoutingAndMapsGeneratedResponse() async throws {
    let transport = GitContentTransport([
      .init(statusCode: 200, body: try fixture("git-repository-description"))
    ])
    let description = try await makeClient(transport).describeRepository(
      repositoryURI: repositoryURI,
      repositoryDID: "did:plc:repository"
    )

    #expect(
      description
        == GitRepositoryDescription(
          ownerDID: "did:plc:owner",
          repositoryDID: "did:plc:repository",
          rkey: "core"
        ))
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.lastPathComponent == "sh.tangled.repo.describeRepo")
    #expect(query("repo", request) == repositoryURI)
    #expect(query("repoDid", request) == "did:plc:repository")
  }

  @Test func languagesMapsCompleteAndOptionalMetadata() async throws {
    let transport = GitContentTransport([
      .init(statusCode: 200, body: try fixture("git-languages")),
      .init(statusCode: 200, body: Data(#"{"ref":"HEAD","languages":[]}"#.utf8)),
    ])
    let client = makeClient(transport)

    let report = try await client.languages(repositoryURI: repositoryURI, ref: "main")
    let empty = try await client.languages(repositoryURI: repositoryURI)

    #expect(report.ref == "main")
    #expect(report.totalFiles == 14)
    #expect(report.totalSize == 10_240)
    #expect(
      report.languages[0]
        == GitLanguage(
          name: "Swift",
          size: 8192,
          percentage: 80,
          fileCount: 12,
          color: "#F05138",
          extensions: [".swift"]
        ))
    #expect(report.languages[1].fileCount == nil)
    #expect(report.languages[1].extensions == nil)
    #expect(empty.ref == "HEAD")
    #expect(empty.languages.isEmpty)
    #expect(empty.totalFiles == nil)

    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.lastPathComponent == "sh.tangled.repo.languages")
    #expect(query("repo", requests[0]) == repositoryURI)
    #expect(query("ref", requests[0]) == "main")
    #expect(query("ref", requests[1]) == nil)
  }

  @Test func archivePreservesBinaryContentAndResponseMetadata() async throws {
    let body = Data([0x50, 0x4B, 0x00, 0xFF, 0x0A])
    let transport = GitContentTransport([
      .init(
        statusCode: 200,
        headers: [
          "Content-Type": "application/zip",
          "Content-Length": "5",
          "Content-Disposition": "attachment; filename=\"example.zip\"",
          "Accept-Ranges": "bytes",
        ],
        body: body
      )
    ])

    let archive = try await makeClient(transport).archive(
      repositoryURI: repositoryURI,
      ref: "release/v1",
      format: .zip,
      prefix: "example-雪"
    )

    #expect(archive.content == body)
    #expect(archive.statusCode == 200)
    #expect(!archive.isPartial)
    #expect(archive.contentType == "application/zip")
    #expect(archive.contentLength == 5)
    #expect(archive.contentDisposition == "attachment; filename=\"example.zip\"")
    #expect(archive.acceptRanges == "bytes")
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.lastPathComponent == "sh.tangled.repo.archive")
    #expect(query("repo", request) == repositoryURI)
    #expect(query("ref", request) == "release/v1")
    #expect(query("format", request) == "zip")
    #expect(query("prefix", request) == "example-雪")
    #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
    #expect(request.value(forHTTPHeaderField: "Range") == nil)
  }

  @Test func archiveSendsByteRangesAndAcceptsPartialOrFullResponses() async throws {
    let transport = GitContentTransport([
      .init(
        statusCode: 206,
        headers: ["Content-Range": "bytes 0-31/100", "Content-Type": "application/gzip"],
        body: Data(repeating: 1, count: 32)
      ),
      .init(statusCode: 200, body: Data(repeating: 2, count: 100)),
      .init(statusCode: 206, body: Data(repeating: 3, count: 8)),
    ])
    let client = makeClient(transport)

    let closed = try await client.archive(
      repositoryURI: repositoryURI,
      ref: "main",
      byteRange: .bytes(0 ... 31)
    )
    let ignored = try await client.archive(
      repositoryURI: repositoryURI,
      ref: "main",
      byteRange: .from(32)
    )
    let suffix = try await client.archive(
      repositoryURI: repositoryURI,
      ref: "main",
      byteRange: .suffix(8)
    )

    #expect(closed.isPartial)
    #expect(closed.contentRange == "bytes 0-31/100")
    #expect(closed.contentType == "application/gzip")
    #expect(!ignored.isPartial)
    #expect(ignored.content.count == 100)
    #expect(suffix.isPartial)
    let requests = await transport.recordedRequests()
    #expect(requests[0].value(forHTTPHeaderField: "Range") == "bytes=0-31")
    #expect(requests[1].value(forHTTPHeaderField: "Range") == "bytes=32-")
    #expect(requests[2].value(forHTTPHeaderField: "Range") == "bytes=-8")
    #expect(requests.allSatisfy { query("format", $0) == "tar.gz" })
  }

  @Test func archiveRejectsInvalidInputsBeforeRequest() async {
    let transport = GitContentTransport([])
    let client = makeClient(transport)

    await expectInvalid {
      _ = try await client.archive(repositoryURI: "invalid", ref: "main")
    }
    await expectInvalid {
      _ = try await client.archive(repositoryURI: repositoryURI, ref: "")
    }
    await expectInvalid {
      _ = try await client.archive(repositoryURI: repositoryURI, ref: "main", prefix: "")
    }
    await expectInvalid {
      _ = try await client.archive(
        repositoryURI: repositoryURI,
        ref: "main",
        byteRange: .bytes(-1 ... 3)
      )
    }
    await expectInvalid {
      _ = try await client.archive(
        repositoryURI: repositoryURI,
        ref: "main",
        byteRange: .from(-1)
      )
    }
    await expectInvalid {
      _ = try await client.archive(
        repositoryURI: repositoryURI,
        ref: "main",
        byteRange: .suffix(0)
      )
    }
    #expect(await transport.requestCount() == 0)
  }

  @Test func archiveFailuresUseExistingTypedErrors() async {
    let transport = GitContentTransport([
      .init(statusCode: 404, body: Data(#"{"error":"RepoNotFound","message":"missing repo"}"#.utf8)),
      .init(statusCode: 502, body: Data(#"{"error":"UpstreamFailed","message":"knot unavailable"}"#.utf8)),
      .init(statusCode: 416, body: Data(#"{"error":"InvalidRange","message":"range rejected"}"#.utf8)),
      .init(statusCode: 500, body: Data(#"{"error":"ArchiveError","message":"archive failed"}"#.utf8)),
    ])
    let client = makeClient(transport)

    do {
      _ = try await client.archive(repositoryURI: repositoryURI, ref: "main")
      Issue.record("Expected notFound")
    } catch TangledError.notFound(let message) {
      #expect(message == "missing repo")
    } catch { Issue.record("Unexpected error: \(error)") }

    do {
      _ = try await client.archive(repositoryURI: repositoryURI, ref: "main")
      Issue.record("Expected upstreamFailed")
    } catch TangledError.upstreamFailed(let message) {
      #expect(message == "knot unavailable")
    } catch { Issue.record("Unexpected error: \(error)") }

    do {
      _ = try await client.archive(repositoryURI: repositoryURI, ref: "main")
      Issue.record("Expected range error")
    } catch TangledError.serverStatus(let status, let message) {
      #expect(status == 416)
      #expect(message == "range rejected")
    } catch { Issue.record("Unexpected error: \(error)") }

    do {
      _ = try await client.archive(repositoryURI: repositoryURI, ref: "main")
      Issue.record("Expected archive error")
    } catch TangledError.serverStatus(let status, let message) {
      #expect(status == 500)
      #expect(message == "archive failed")
    } catch { Issue.record("Unexpected error: \(error)") }
  }

  @Test func logDecodesWireShapeAndDerivesOffsetCursor() async throws {
    let transport = GitContentTransport([
      .init(statusCode: 200, body: try fixture("git-log"))
    ])
    let page = try await makeClient(transport).log(
      repositoryURI: repositoryURI,
      ref: "main",
      path: "Sources",
      cursor: "2",
      limit: 2
    )

    #expect(page.ref == "main")
    #expect(page.total == 5)
    #expect(page.page == 2)
    #expect(page.cursor == "4")
    #expect(page.commits[0].hash == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(page.commits[0].author.name == "Alice")
    #expect(page.commits[0].parentHashes == ["cccccccccccccccccccccccccccccccccccccccc"])
    #expect(page.commits[0].changeID == "change-one")

    let request = try #require(await transport.recordedRequests().first)
    #expect(query("cursor", request) == "2")
    #expect(query("limit", request) == "2")
    #expect(query("path", request) == "Sources")
  }

  @Test func blobNormalizesTextBinaryAndSubmoduleResponses() async throws {
    let transport = GitContentTransport([
      .init(statusCode: 200, body: try fixture("git-blob-text")),
      .init(statusCode: 200, body: try fixture("git-blob-binary")),
      .init(statusCode: 200, body: try fixture("git-blob-submodule")),
      .init(statusCode: 200, body: try fixture("git-blob-too-large")),
    ])
    let client = makeClient(transport)

    let text = try await client.blob(repositoryURI: repositoryURI, ref: "main", path: "README.md")
    let binary = try await client.blob(repositoryURI: repositoryURI, ref: "main", path: "icon.bin")
    let submodule = try await client.blob(
      repositoryURI: repositoryURI,
      ref: "main",
      path: "Vendor/Dependency"
    )
    let tooLarge = try await client.blob(
      repositoryURI: repositoryURI,
      ref: "main",
      path: "large.bin"
    )

    #expect(text.content == Data("# Example\n".utf8))
    #expect(text.encoding == .utf8)
    #expect(binary.content == Data([0x00, 0xFF, 0x0A]))
    #expect(binary.encoding == .base64)
    #expect(binary.isBinary)
    #expect(submodule.content == nil)
    #expect(
      submodule.submodule
        == GitSubmodule(
          name: "Dependency",
          url: "https://example.com/dependency.git",
          branch: "stable"
        ))
    #expect(tooLarge.content == nil)
    #expect(tooLarge.fileTooLarge)

    let request = try #require(await transport.recordedRequests().first)
    #expect(query("repo", request) == repositoryURI)
    #expect(query("raw", request) == nil)
  }

  @Test func invalidInputsFailBeforeNetworkRequest() async {
    let transport = GitContentTransport([])
    let client = makeClient(transport)

    await expectInvalid { _ = try await client.defaultBranch(repositoryURI: "") }
    await expectInvalid { _ = try await client.branches(repositoryURI: "") }
    await expectInvalid { _ = try await client.branches(repositoryURI: repositoryURI, cursor: "sha") }
    await expectInvalid { _ = try await client.branches(repositoryURI: repositoryURI, limit: 0) }
    await expectInvalid { _ = try await client.tags(repositoryURI: repositoryURI, cursor: "-1") }
    await expectInvalid { _ = try await client.tags(repositoryURI: repositoryURI, limit: 101) }
    await expectInvalid {
      _ = try await client.describeRepository(
        repositoryURI: "did:plc:repo",
        repositoryDID: "did:plc:repository"
      )
    }
    await expectInvalid {
      _ = try await client.describeRepository(
        repositoryURI: repositoryURI,
        repositoryDID: "not-a-did"
      )
    }
    await expectInvalid { _ = try await client.languages(repositoryURI: repositoryURI, ref: "") }
    await expectInvalid { _ = try await client.tree(repositoryURI: "did:plc:repo", ref: "main") }
    await expectInvalid { _ = try await client.tree(repositoryURI: repositoryURI, ref: "") }
    await expectInvalid { _ = try await client.tree(repositoryURI: repositoryURI, ref: "main", path: "") }
    await expectInvalid { _ = try await client.log(repositoryURI: repositoryURI, ref: "main", cursor: "sha") }
    await expectInvalid { _ = try await client.log(repositoryURI: repositoryURI, ref: "main", limit: 0) }
    await expectInvalid { _ = try await client.log(repositoryURI: repositoryURI, ref: "main", limit: 101) }
    await expectInvalid { _ = try await client.blob(repositoryURI: repositoryURI, ref: "main", path: "") }
    #expect(await transport.requestCount() == 0)
  }

  @Test func gitReferenceFailuresStayTyped() async {
    let transport = GitContentTransport([
      .init(statusCode: 404, body: Data(#"{"error":"RepoNotFound","message":"missing repo"}"#.utf8)),
      .init(statusCode: 200, body: Data(#"{"tags":"invalid"}"#.utf8)),
    ])
    let client = makeClient(transport)

    do {
      _ = try await client.branches(repositoryURI: repositoryURI)
      Issue.record("Expected notFound")
    } catch TangledError.notFound(let message) {
      #expect(message == "missing repo")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    do {
      _ = try await client.tags(repositoryURI: repositoryURI)
      Issue.record("Expected decoding error")
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func repositoryMetadataFailuresStayTyped() async {
    let transport = GitContentTransport([
      .init(statusCode: 404, body: Data(#"{"error":"RepoNotFound","message":"missing repo"}"#.utf8)),
      .init(statusCode: 404, body: Data(#"{"error":"RefNotFound","message":"missing ref"}"#.utf8)),
      .init(statusCode: 502, body: Data(#"{"error":"UpstreamFailed","message":"knot unavailable"}"#.utf8)),
      .init(statusCode: 200, body: Data(#"{"ref":"main"}"#.utf8)),
    ])
    let client = makeClient(transport)

    do {
      _ = try await client.describeRepository(
        repositoryURI: repositoryURI,
        repositoryDID: "did:plc:repository"
      )
      Issue.record("Expected notFound")
    } catch TangledError.notFound(let message) {
      #expect(message == "missing repo")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    do {
      _ = try await client.languages(repositoryURI: repositoryURI, ref: "missing")
      Issue.record("Expected notFound")
    } catch TangledError.notFound(let message) {
      #expect(message == "missing ref")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    do {
      _ = try await client.languages(repositoryURI: repositoryURI)
      Issue.record("Expected upstream failure")
    } catch TangledError.upstreamFailed(let message) {
      #expect(message == "knot unavailable")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    do {
      _ = try await client.languages(repositoryURI: repositoryURI)
      Issue.record("Expected decoding error")
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func malformedBase64AndHTTPFailuresStayTyped() async throws {
    let transport = GitContentTransport([
      .init(statusCode: 200, body: Data(#"{"ref":"main","path":"x","content":"%%%","encoding":"base64"}"#.utf8)),
      .init(statusCode: 404, body: Data(#"{"error":"FileNotFound","message":"missing file"}"#.utf8)),
    ])
    let client = makeClient(transport)

    do {
      _ = try await client.blob(repositoryURI: repositoryURI, ref: "main", path: "x")
      Issue.record("Expected decoding error")
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    do {
      _ = try await client.blob(repositoryURI: repositoryURI, ref: "main", path: "missing")
      Issue.record("Expected notFound")
    } catch TangledError.notFound(let message) {
      #expect(message == "missing file")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func upstreamFailureAndMalformedLogStayTyped() async {
    let transport = GitContentTransport([
      .init(
        statusCode: 502,
        body: Data(#"{"error":"UpstreamFailed","message":"knot unavailable"}"#.utf8)
      ),
      .init(statusCode: 200, body: Data(#"{"commits":[]}"#.utf8)),
    ])
    let client = makeClient(transport)

    do {
      _ = try await client.tree(repositoryURI: repositoryURI, ref: "main")
      Issue.record("Expected upstreamFailed")
    } catch TangledError.upstreamFailed(let message) {
      #expect(message == "knot unavailable")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    do {
      _ = try await client.log(repositoryURI: repositoryURI, ref: "main")
      Issue.record("Expected decoding error")
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func diffMapsStructuredResponseAndPreservesUnknownOperations() async throws {
    let transport = GitContentTransport([
      .init(statusCode: 200, body: try fixture("git-diff"))
    ])

    let diff = try await makeClient(transport).diff(
      repositoryURI: repositoryURI,
      ref: "feature"
    )

    #expect(diff.ref == "feature")
    #expect(diff.commit.hash == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(diff.commit.parentHashes == ["cccccccccccccccccccccccccccccccccccccccc"])
    #expect(diff.stat == GitDiffStat(insertions: 1, deletions: 1, filesChanged: 2))
    #expect(diff.files[0].path == "hello.txt")
    #expect(diff.files[0].textFragments[0].lines[0].operation == .deletion)
    #expect(diff.files[0].textFragments[0].lines[1].operation == .addition)
    #expect(diff.files[0].textFragments[0].lines[2].operation.rawValue == 9)
    #expect(diff.files[1].isBinary)
    #expect(diff.files[1].textFragments.isEmpty)

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.lastPathComponent == "sh.tangled.repo.diff")
    #expect(query("repo", request) == repositoryURI)
    #expect(query("ref", request) == "feature")
  }

  @Test func compareMapsPatchesAndPreservesUnifiedText() async throws {
    let transport = GitContentTransport([
      .init(statusCode: 200, body: try fixture("git-compare"))
    ])

    let comparison = try await makeClient(transport).compare(
      repositoryURI: repositoryURI,
      baseRevision: "main",
      headRevision: "feature"
    )

    #expect(comparison.baseRevision == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(comparison.headRevision == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    #expect(comparison.patch == "From bbbbbbb\n\ndiff --git a/old.txt b/new.txt\n\n")
    #expect(comparison.combinedPatch == "diff --git a/old.txt b/new.txt\n")
    #expect(comparison.formatPatches[0].author.name == "Alice")
    #expect(comparison.formatPatches[0].committer?.name == "Tangled")
    #expect(comparison.formatPatches[0].headers["Change-Id"] == ["change-one"])
    #expect(comparison.formatPatches[0].files[0].isRename)
    #expect(comparison.formatPatches[0].files[0].path == "new.txt")
    #expect(comparison.combinedFiles[0].oldObjectIDPrefix == "1111111")

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.lastPathComponent == "sh.tangled.repo.compare")
    #expect(query("repo", request) == repositoryURI)
    #expect(query("rev1", request) == "main")
    #expect(query("rev2", request) == "feature")
  }

  @Test func diffAndCompareRejectInvalidInputsBeforeNetworkRequest() async {
    let transport = GitContentTransport([])
    let client = makeClient(transport)

    await expectInvalid { _ = try await client.diff(repositoryURI: "", ref: "main") }
    await expectInvalid { _ = try await client.diff(repositoryURI: repositoryURI, ref: "") }
    await expectInvalid {
      _ = try await client.compare(
        repositoryURI: "did:plc:repo",
        baseRevision: "main",
        headRevision: "feature"
      )
    }
    await expectInvalid {
      _ = try await client.compare(
        repositoryURI: repositoryURI,
        baseRevision: "",
        headRevision: "feature"
      )
    }
    await expectInvalid {
      _ = try await client.compare(
        repositoryURI: repositoryURI,
        baseRevision: "main",
        headRevision: ""
      )
    }
    #expect(await transport.requestCount() == 0)
  }

  @Test func comparePreservesLargePatchWithoutAddingOrRemovingBytes() async throws {
    let patch = String(repeating: "diff line with spaces  \n", count: 50_000)
    let body = try JSONSerialization.data(withJSONObject: [
      "rev1": "base",
      "rev2": "head",
      "format_patch": [],
      "patch": patch,
    ])
    let transport = GitContentTransport([.init(statusCode: 200, body: body)])

    let result = try await makeClient(transport).compare(
      repositoryURI: repositoryURI,
      baseRevision: "base",
      headRevision: "head"
    )

    #expect(result.patch == patch)
    #expect(result.combinedFiles.isEmpty)
    #expect(result.combinedPatch.isEmpty)
  }

  @Test func diffAndCompareFailuresStayTyped() async {
    let transport = GitContentTransport([
      .init(statusCode: 200, body: Data(#"{"ref":"main"}"#.utf8)),
      .init(statusCode: 404, body: Data(#"{"error":"RefNotFound","message":"missing ref"}"#.utf8)),
      .init(statusCode: 502, body: Data(#"{"error":"UpstreamFailed","message":"knot unavailable"}"#.utf8)),
    ])
    let client = makeClient(transport)

    do {
      _ = try await client.diff(repositoryURI: repositoryURI, ref: "main")
      Issue.record("Expected decoding error")
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    do {
      _ = try await client.diff(repositoryURI: repositoryURI, ref: "missing")
      Issue.record("Expected notFound")
    } catch TangledError.notFound(let message) {
      #expect(message == "missing ref")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    do {
      _ = try await client.compare(
        repositoryURI: repositoryURI,
        baseRevision: "main",
        headRevision: "feature"
      )
      Issue.record("Expected upstream failure")
    } catch TangledError.upstreamFailed(let message) {
      #expect(message == "knot unavailable")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

private extension GitContentAPITests {
  func makeClient(_ transport: GitContentTransport) -> BobbinClient {
    BobbinClient(
      baseURL: URL(string: "https://bobbin.example/base")!,
      transport: transport,
      retryPolicy: BobbinRetryPolicy(maxAttempts: 1)
    )
  }

  func fixture(_ name: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
      ))
    return try Data(contentsOf: url)
  }

  func query(_ name: String, _ request: URLRequest) -> String? {
    guard let url = request.url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == name }?.value
  }

  func expectInvalid(_ operation: () async throws -> Void) async {
    do {
      try await operation()
      Issue.record("Expected invalidRequest")
    } catch TangledError.invalidRequest {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

private actor GitContentTransport: HTTPTransport {
  struct Response: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data) {
      self.statusCode = statusCode
      self.headers = headers
      self.body = body
    }
  }

  private var responses: [Response]
  private var requests: [URLRequest] = []

  init(_ responses: [Response]) {
    self.responses = responses
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    guard !responses.isEmpty else { throw URLError(.unknown) }
    let response = responses.removeFirst()
    return (
      response.body,
      HTTPURLResponse(
        url: request.url!,
        statusCode: response.statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: response.headers
      )!
    )
  }

  func recordedRequests() -> [URLRequest] { requests }
  func requestCount() -> Int { requests.count }
}
