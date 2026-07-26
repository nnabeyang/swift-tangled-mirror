import Foundation
import SwiftAtproto
import Testing

@testable import SwiftTangled

#if canImport(zlib)
  import zlib
#else
  import CZlib
#endif

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct PullRequestPatchLoaderTests {
  private let pullURI = "at://did:plc:author/sh.tangled.repo.pull/3mr3itrannf22"

  @Test func latestRoundFetchesOwnerPDSBlobAndExtractsMultipleDiffs() async throws {
    let signature = "-- "
    let rawPatch = Data(
      """
      From aaaaaaa Mon Sep 17 00:00:00 2001
      Subject: [PATCH 1/2] first

      diff --git a/first.txt b/first.txt
      --- a/first.txt
      +++ b/first.txt
      @@ -1 +1 @@
      -old
      +new
      \(signature)
      2.54.0

      From bbbbbbb Mon Sep 17 00:00:00 2001
      Subject: [PATCH 2/2] second

      diff --git a/second.txt b/second.txt
      new file mode 100644
      --- /dev/null
      +++ b/second.txt
      @@ -0,0 +1 @@
      +second
      \(signature)
      2.54.0

      """.utf8
    )
    let blobTransport = PatchTransport([
      .init(statusCode: 200, body: try gzip(rawPatch))
    ])
    let loader = try makeLoader(blobTransport: blobTransport)

    let result = try await loader.load(pullRequestURI: pullURI)

    #expect(result.roundNumber == 1)
    #expect(result.totalRounds == 2)
    #expect(result.blob.cid == "bafkreiroundtwo")
    #expect(result.rawPatch == rawPatch)
    #expect(
      String(decoding: result.unifiedDiff, as: UTF8.self)
        == """
        diff --git a/first.txt b/first.txt
        --- a/first.txt
        +++ b/first.txt
        @@ -1 +1 @@
        -old
        +new
        diff --git a/second.txt b/second.txt
        new file mode 100644
        --- /dev/null
        +++ b/second.txt
        @@ -0,0 +1 @@
        +second

        """
    )

    let request = try #require(await blobTransport.recordedRequests().first)
    #expect(request.url?.host == "pds.example")
    #expect(request.url?.lastPathComponent == "com.atproto.sync.getBlob")
    #expect(query("did", request) == "did:plc:author")
    #expect(query("cid", request) == "bafkreiroundtwo")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
  }

  @Test func explicitRoundUsesZeroBasedNumberAndPreservesRawDiffBytes() async throws {
    let rawDiff = Data("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a  \n+b\n".utf8)
    let blobTransport = PatchTransport([
      .init(statusCode: 200, body: try gzip(rawDiff))
    ])
    let loader = try makeLoader(blobTransport: blobTransport)

    let result = try await loader.load(pullRequestURI: pullURI, roundNumber: 0)

    #expect(result.roundNumber == 0)
    #expect(result.blob.cid == "bafkreiroundone")
    #expect(result.unifiedDiff == rawDiff)
    let request = try #require(await blobTransport.recordedRequests().first)
    #expect(query("cid", request) == "bafkreiroundone")
  }

  @Test func invalidURIAndRoundFailBeforeBlobRequest() async throws {
    let blobTransport = PatchTransport([])
    let resolver = PatchResolver()
    let loader = try makeLoader(blobTransport: blobTransport, resolver: resolver)

    await expectInvalid {
      _ = try await loader.load(pullRequestURI: "not-an-at-uri")
    }
    await expectInvalid {
      _ = try await loader.load(pullRequestURI: pullURI, roundNumber: -1)
    }
    await expectInvalid {
      _ = try await loader.load(pullRequestURI: pullURI, roundNumber: 2)
    }
    #expect(await blobTransport.recordedRequests().isEmpty)
    #expect(await resolver.resolvedDIDs().isEmpty)
  }

  @Test func missingBlobMalformedGzipAndMissingDiffStayTyped() async throws {
    let notFound = PatchTransport([
      .init(statusCode: 404, body: Data())
    ])
    do {
      _ = try await makeLoader(blobTransport: notFound).load(pullRequestURI: pullURI)
      Issue.record("Expected notFound")
    } catch TangledError.notFound(let message) {
      #expect(message == "pull request patch blob not found")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let malformed = PatchTransport([
      .init(statusCode: 200, body: Data("not gzip".utf8))
    ])
    await expectDecoding {
      _ = try await makeLoader(blobTransport: malformed).load(pullRequestURI: pullURI)
    }

    let noDiff = PatchTransport([
      .init(statusCode: 200, body: try gzip(Data("Subject: no diff\n".utf8)))
    ])
    await expectDecoding {
      _ = try await makeLoader(blobTransport: noDiff).load(pullRequestURI: pullURI)
    }
  }
}

extension PullRequestPatchLoaderTests {
  fileprivate func makeLoader(
    blobTransport: PatchTransport,
    resolver: PatchResolver = PatchResolver()
  ) throws -> PullRequestPatchLoader {
    return PullRequestPatchLoader(
      pullRequest: { _ in try self.pullRequestRecord() },
      resolver: resolver,
      transport: blobTransport
    )
  }

  fileprivate func pullRequestRecord() throws -> TangledRecord<PullRequest> {
    TangledRecord(
      uri: pullURI,
      cid: "bafypull",
      value: PullRequest(
        title: "Patch rounds",
        rounds: [
          PullRequestRound(
            createdAt: FormatString<Date>(rawValue: "2026-07-20T00:00:00Z"),
            patchBlob: BlobReference(
              cid: "bafkreiroundone",
              mimeType: "application/gzip",
              size: 100
            )
          ),
          PullRequestRound(
            createdAt: FormatString<Date>(rawValue: "2026-07-21T00:00:00Z"),
            patchBlob: BlobReference(
              cid: "bafkreiroundtwo",
              mimeType: "application/gzip",
              size: 200
            )
          ),
        ],
        target: PullRequestTarget(
          branch: "main",
          repositoryDID: "did:plc:repository"
        ),
        createdAt: FormatString<Date>(rawValue: "2026-07-20T00:00:00Z")
      )
    )
  }

  fileprivate func query(_ name: String, _ request: URLRequest) -> String? {
    guard let url = request.url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == name }?.value
  }

  fileprivate func expectInvalid(_ operation: () async throws -> Void) async {
    do {
      try await operation()
      Issue.record("Expected invalidRequest")
    } catch TangledError.invalidRequest {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  fileprivate func expectDecoding(_ operation: () async throws -> Void) async {
    do {
      try await operation()
      Issue.record("Expected decoding error")
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  fileprivate func gzip(_ data: Data) throws -> Data {
    let input = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
    defer { input.deallocate() }
    data.copyBytes(to: input, count: data.count)
    let bound = Int(compressBound(uLong(data.count))) + 32
    let output = UnsafeMutablePointer<UInt8>.allocate(capacity: bound)
    defer { output.deallocate() }

    var stream = z_stream()
    stream.next_in = input
    stream.avail_in = uInt(data.count)
    stream.next_out = output
    stream.avail_out = uInt(bound)
    let initialized = deflateInit2_(
      &stream,
      Z_DEFAULT_COMPRESSION,
      Z_DEFLATED,
      15 + 16,
      8,
      Z_DEFAULT_STRATEGY,
      ZLIB_VERSION,
      Int32(MemoryLayout<z_stream>.size)
    )
    guard initialized == Z_OK else { throw PatchTestError.gzip }
    defer { deflateEnd(&stream) }
    guard deflate(&stream, Z_FINISH) == Z_STREAM_END else { throw PatchTestError.gzip }
    return Data(bytes: output, count: bound - Int(stream.avail_out))
  }
}

private actor PatchTransport: HTTPTransport {
  struct Response: Sendable {
    let statusCode: Int
    let body: Data
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
        headerFields: [:]
      )!
    )
  }

  func recordedRequests() -> [URLRequest] { requests }
}

private actor PatchResolver: ATPResolver {
  private var dids: [DID] = []

  func resolve(handle: Handle) async throws -> DID? { nil }

  func resolve(did: DID) async throws -> DIDDocument? {
    dids.append(did)
    return DIDDocument(
      context: ["https://www.w3.org/ns/did/v1"],
      did: FormatString(rawValue: did.rawValue),
      service: [
        DocService(
          id: "#atproto_pds",
          type: "AtprotoPersonalDataServer",
          serviceEndpoint: "https://pds.example/base"
        )
      ]
    )
  }

  func resolvedDIDs() -> [DID] { dids }
}

private enum PatchTestError: Error {
  case gzip
}
