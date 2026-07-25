import Foundation
import SwiftAtproto
import SwiftTangled
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct TangledRecordReaderTests {
  private let ownerDID = "did:plc:owner"
  private let repositoryDID = "did:plc:repository"
  private let rkey = "3mrecord"

  @Test func pdsSuccessSkipsBobbinAndReportsSource() async throws {
    let pdsTransport = ReaderTransport([
      pdsResponse(
        collection: "sh.tangled.repo.issue",
        value:
          """
          {"$type":"sh.tangled.repo.issue","repo":"\(repositoryDID)","title":"Fresh","createdAt":"2026-07-26T00:00:00Z"}
          """
      )
    ])
    let bobbinTransport = ReaderTransport([])
    let reader = makeReader(pdsTransport: pdsTransport, bobbinTransport: bobbinTransport)

    let result = try await reader.issue(uri: uri(collection: "sh.tangled.repo.issue"))

    #expect(result.source == .pds)
    #expect(result.record.value.title == "Fresh")
    #expect(await bobbinTransport.recordedRequests().isEmpty)
  }

  @Test func temporaryPDSFailuresFallBackForSupportedRecords() async throws {
    let pdsTransport = ReaderTransport([])
    let bobbinTransport = ReaderTransport([
      bobbinResponse(
        value:
          """
          {"name":"core","knot":"knot.example","repoDid":"\(repositoryDID)","createdAt":"2026-07-26T00:00:00Z"}
          """
      ),
      bobbinResponse(
        value:
          """
          {"repo":"\(repositoryDID)","title":"Indexed issue","createdAt":"2026-07-26T00:01:00Z"}
          """
      ),
      bobbinResponse(
        value:
          """
          {"title":"Indexed pull","rounds":[],"target":{"branch":"main","repo":"\(repositoryDID)"},"createdAt":"2026-07-26T00:02:00Z"}
          """
      ),
    ])
    let reader = makeReader(pdsTransport: pdsTransport, bobbinTransport: bobbinTransport)

    let repository = try await reader.repository(uri: uri(collection: "sh.tangled.repo"))
    let issue = try await reader.issue(uri: uri(collection: "sh.tangled.repo.issue"))
    let pull = try await reader.pullRequest(uri: uri(collection: "sh.tangled.repo.pull"))

    #expect(repository.source == .bobbinFallback)
    #expect(issue.source == .bobbinFallback)
    #expect(pull.source == .bobbinFallback)
    #expect(repository.record.value.name == "core")
    #expect(issue.record.value.title == "Indexed issue")
    #expect(pull.record.value.title == "Indexed pull")
  }

  @Test func authoritativeNotFoundNeverFallsBack() async {
    let pdsTransport = ReaderTransport([
      .init(
        statusCode: 400,
        body: Data(#"{"error":"RecordNotFound","message":"deleted"}"#.utf8)
      )
    ])
    let bobbinTransport = ReaderTransport([
      bobbinResponse(
        value:
          """
          {"repo":"\(repositoryDID)","title":"Stale issue","createdAt":"2026-07-26T00:00:00Z"}
          """
      )
    ])
    let reader = makeReader(pdsTransport: pdsTransport, bobbinTransport: bobbinTransport)

    do {
      _ = try await reader.issue(uri: uri(collection: "sh.tangled.repo.issue"))
      Issue.record("Expected authoritative notFound")
    } catch TangledError.notFound(let message) {
      #expect(message == "deleted")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await bobbinTransport.recordedRequests().isEmpty)
  }

  @Test func artifactDoesNotUseUnavailableBobbinFallback() async {
    let pdsTransport = ReaderTransport([])
    let bobbinTransport = ReaderTransport([])
    let reader = makeReader(pdsTransport: pdsTransport, bobbinTransport: bobbinTransport)

    do {
      _ = try await reader.artifact(uri: uri(collection: "sh.tangled.repo.artifact"))
      Issue.record("Expected network failure")
    } catch TangledError.network {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await bobbinTransport.recordedRequests().isEmpty)
  }

  @Test func failedFallbackPreservesThePDSFailure() async {
    let pdsTransport = ReaderTransport([
      .init(
        statusCode: 503,
        body: Data(#"{"error":"Unavailable","message":"PDS unavailable"}"#.utf8)
      )
    ])
    let bobbinTransport = ReaderTransport([
      .init(statusCode: 404, body: Data(#"{"error":"NotFound"}"#.utf8))
    ])
    let reader = makeReader(pdsTransport: pdsTransport, bobbinTransport: bobbinTransport)

    do {
      _ = try await reader.repository(uri: uri(collection: "sh.tangled.repo"))
      Issue.record("Expected the original PDS failure")
    } catch TangledError.serviceUnavailable(let message) {
      #expect(message == "PDS unavailable")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await bobbinTransport.recordedRequests().count == 1)
  }

  @Test func sourcedRecordSupportsCodableRoundTrips() throws {
    let value = TangledRecordRead(
      record: TangledRecord(
        uri: uri(collection: "sh.tangled.repo"),
        cid: "bafyrecord",
        value: Repository(
          name: "core",
          knot: "knot.example",
          repoDID: repositoryDID,
          createdAt: FormatString(rawValue: "2026-07-26T00:00:00Z")
        )
      ),
      source: TangledRecordSource.bobbinFallback
    )

    let decoded = try JSONDecoder().decode(
      TangledRecordRead<Repository>.self,
      from: JSONEncoder().encode(value)
    )

    #expect(decoded == value)
  }
}

extension TangledRecordReaderTests {
  fileprivate func makeReader(
    pdsTransport: ReaderTransport,
    bobbinTransport: ReaderTransport
  ) -> TangledRecordReader {
    TangledRecordReader(
      pdsClient: PDSRecordClient(
        resolver: ReaderResolver(document: document()),
        transport: pdsTransport
      ),
      bobbinClient: BobbinClient(
        baseURL: URL(string: "https://bobbin.example")!,
        transport: bobbinTransport,
        retryPolicy: BobbinRetryPolicy(maxAttempts: 1)
      )
    )
  }

  fileprivate func document() -> DIDDocument {
    DIDDocument(
      context: ["https://www.w3.org/ns/did/v1"],
      did: FormatString(rawValue: ownerDID),
      service: [
        .init(
          id: "#atproto_pds",
          type: "AtprotoPersonalDataServer",
          serviceEndpoint: "https://pds.example"
        )
      ]
    )
  }

  fileprivate func uri(collection: String) -> String {
    "at://\(ownerDID)/\(collection)/\(rkey)"
  }

  fileprivate func pdsResponse(
    collection: String,
    value: String
  ) -> ReaderTransport.Response {
    .init(
      statusCode: 200,
      body: Data(
        """
        {"uri":"\(uri(collection: collection))","cid":"bafypds","value":\(value)}
        """.utf8
      )
    )
  }

  fileprivate func bobbinResponse(value: String) -> ReaderTransport.Response {
    .init(
      statusCode: 200,
      body: Data(
        """
        {"uri":"at://\(ownerDID)/unused/\(rkey)","cid":"bafybobbin","value":\(value)}
        """.utf8
      )
    )
  }
}

private struct ReaderResolver: ATPResolver {
  let document: DIDDocument?

  func resolve(handle: Handle) async throws -> DID? {
    nil
  }

  func resolve(did: DID) async throws -> DIDDocument? {
    document
  }
}

private actor ReaderTransport: HTTPTransport {
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
    guard !responses.isEmpty else {
      throw URLError(.cannotConnectToHost)
    }
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

  func recordedRequests() -> [URLRequest] {
    requests
  }
}
