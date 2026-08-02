import Foundation
import SwiftAtproto
import TangledLexicons

#if canImport(zlib)
  import zlib
#else
  import CZlib
#endif

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct PullRequestPatchLoader: Sendable {
  private let pullRequest: @Sendable (String) async throws -> TangledRecord<PullRequest>
  private let resolver: any ATPResolver
  private let transport: any HTTPTransport

  public init(
    pdsRecordClient: PDSRecordClient = PDSRecordClient(),
    resolver: any ATPResolver = URLSessionATPResolver(),
    transport: any HTTPTransport = URLSessionTransport()
  ) {
    self.pullRequest = { try await pdsRecordClient.pullRequest(uri: $0) }
    self.resolver = resolver
    self.transport = transport
  }

  init(
    pullRequest: @escaping @Sendable (String) async throws -> TangledRecord<PullRequest>,
    resolver: any ATPResolver,
    transport: any HTTPTransport
  ) {
    self.pullRequest = pullRequest
    self.resolver = resolver
    self.transport = transport
  }

  public func load(
    pullRequestURI: String,
    roundNumber: Int? = nil
  ) async throws -> PullRequestPatch {
    _ = try pullRequestOwnerDID(pullRequestURI)
    let record = try await pullRequest(pullRequestURI)
    guard record.uri == pullRequestURI else {
      throw TangledError.upstreamFailed(
        "PDS returned a different pull request record: \(record.uri)"
      )
    }
    return try await load(record: record, roundNumber: roundNumber)
  }

  func load(
    record: TangledRecord<PullRequest>,
    roundNumber: Int? = nil
  ) async throws -> PullRequestPatch {
    let ownerDID = try pullRequestOwnerDID(record.uri)
    let rounds = record.value.rounds
    guard !rounds.isEmpty else {
      throw TangledError.notFound("pull request has no rounds")
    }

    let selectedRound = roundNumber ?? rounds.count - 1
    guard rounds.indices.contains(selectedRound) else {
      throw TangledError.invalidRequest(
        "round must be between 0 and \(rounds.count - 1)"
      )
    }
    let round = rounds[selectedRound]
    let compressed = try await fetchBlob(did: ownerDID, cid: round.patchBlob.cid)
    let rawPatch = try Gzip.decompress(compressed)
    let unifiedDiff = try UnifiedDiffExtractor.extract(from: rawPatch)
    return PullRequestPatch(
      pullRequestURI: record.uri,
      roundNumber: selectedRound,
      totalRounds: rounds.count,
      createdAt: round.createdAt,
      blob: round.patchBlob,
      rawPatch: rawPatch,
      unifiedDiff: unifiedDiff
    )
  }
}

extension PullRequestPatchLoader {
  fileprivate func pullRequestOwnerDID(_ value: String) throws(TangledError) -> DID {
    let uri: ATURI
    do {
      uri = try ATURI(string: value)
    } catch {
      throw TangledError.invalidRequest("invalid pull request AT URI")
    }
    guard uri.collection?.rawValue == Sh.Tangled.RepoPull.nsId, uri.rkey != nil else {
      throw TangledError.invalidRequest(
        "pull request URI must identify a \(Sh.Tangled.RepoPull.nsId) record"
      )
    }
    guard case .did(let did) = uri.authority else {
      throw TangledError.invalidRequest("pull request URI owner must be a DID")
    }
    return did
  }

  fileprivate func fetchBlob(did: DID, cid: String) async throws -> Data {
    guard !cid.isEmpty else {
      throw TangledError.decoding(PullRequestPatchError.missingBlobCID)
    }
    guard let document = try await resolver.resolve(did: did) else {
      throw TangledError.handleNotResolved("DID document not found: \(did.rawValue)")
    }
    let pdsURL: URL
    do {
      pdsURL = try document.pdsUrl
    } catch {
      throw TangledError.handleNotResolved("PDS not found for \(did.rawValue)")
    }
    do {
      return try await HTTPXRPCClient(
        baseURL: pdsURL,
        transport: transport,
        accept: "application/octet-stream"
      ).SyncGetBlob(
        cid: FormatString(rawValue: cid),
        did: .init(did)
      )
    } catch Com.Atproto.SyncGetBlob.Error.blobnotfound,
      Com.Atproto.SyncGetBlob.Error.reponotfound,
      TangledError.notFound
    {
      throw TangledError.notFound("pull request patch blob not found")
    }
  }
}

private enum Gzip {
  static func decompress(_ data: Data) throws(TangledError) -> Data {
    guard !data.isEmpty, data.count <= Int(UInt32.max) else {
      throw TangledError.decoding(PullRequestPatchError.invalidGzip)
    }

    let input = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
    defer { input.deallocate() }
    data.copyBytes(to: input, count: data.count)

    let bufferSize = 64 * 1024
    let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { outputBuffer.deallocate() }

    var stream = z_stream()
    stream.next_in = input
    stream.avail_in = uInt(data.count)
    let initialization = inflateInit2_(
      &stream,
      15 + 32,
      ZLIB_VERSION,
      Int32(MemoryLayout<z_stream>.size)
    )
    guard initialization == Z_OK else {
      throw TangledError.decoding(PullRequestPatchError.invalidGzip)
    }
    defer { inflateEnd(&stream) }

    var output = Data()
    while true {
      stream.next_out = outputBuffer
      stream.avail_out = uInt(bufferSize)
      let result = inflate(&stream, Z_NO_FLUSH)
      guard result == Z_OK || result == Z_STREAM_END else {
        throw TangledError.decoding(PullRequestPatchError.invalidGzip)
      }
      let produced = bufferSize - Int(stream.avail_out)
      output.append(outputBuffer, count: produced)
      if result == Z_STREAM_END { return output }
      guard stream.avail_in > 0 || produced > 0 else {
        throw TangledError.decoding(PullRequestPatchError.invalidGzip)
      }
    }
  }
}

private enum UnifiedDiffExtractor {
  private static let diffHeader = Data("diff --git ".utf8)
  private static let signature = Data("-- ".utf8)

  static func extract(from patch: Data) throws(TangledError) -> Data {
    let lines = lineRanges(in: patch)
    var result = Data()
    var isReadingDiff = false
    var foundDiff = false

    for index in lines.indices {
      let content = lineContent(patch, range: lines[index])
      if content.starts(with: diffHeader) {
        isReadingDiff = true
        foundDiff = true
      } else if isReadingDiff, content == signature,
        isFormatPatchSignature(lines: lines, index: index, data: patch)
      {
        isReadingDiff = false
        continue
      }
      if isReadingDiff {
        result.append(patch[lines[index]])
      }
    }

    guard foundDiff else {
      throw TangledError.decoding(PullRequestPatchError.missingUnifiedDiff)
    }
    return result
  }

  private static func lineRanges(in data: Data) -> [Range<Data.Index>] {
    var ranges: [Range<Data.Index>] = []
    var start = data.startIndex
    var index = start
    while index < data.endIndex {
      if data[index] == 0x0A {
        let end = data.index(after: index)
        ranges.append(start ..< end)
        start = end
      }
      index = data.index(after: index)
    }
    if start < data.endIndex { ranges.append(start ..< data.endIndex) }
    return ranges
  }

  private static func lineContent(_ data: Data, range: Range<Data.Index>) -> Data {
    var end = range.upperBound
    if end > range.lowerBound, data[data.index(before: end)] == 0x0A {
      end = data.index(before: end)
    }
    if end > range.lowerBound, data[data.index(before: end)] == 0x0D {
      end = data.index(before: end)
    }
    return data[range.lowerBound ..< end]
  }

  private static func isFormatPatchSignature(
    lines: [Range<Data.Index>],
    index: Int,
    data: Data
  ) -> Bool {
    let next = index + 1
    guard next < lines.count else { return false }
    let version = lineContent(data, range: lines[next])
    guard !version.isEmpty else { return false }
    return version.allSatisfy { (0x30 ... 0x39).contains($0) || $0 == 0x2E }
  }
}

private enum PullRequestPatchError: Error, Sendable {
  case missingBlobCID
  case invalidGzip
  case missingUnifiedDiff
}
