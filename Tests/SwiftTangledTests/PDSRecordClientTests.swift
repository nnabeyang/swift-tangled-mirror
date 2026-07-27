import Foundation
import SwiftAtproto
import SwiftTangled
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct PDSRecordClientTests {
  private let ownerDID = "did:plc:owner"
  private let repositoryDID = "did:plc:repository"
  private let rkey = "3mrecord"

  @Test(arguments: [
    #""AAAAAAAAAAAAAAAAAAAAAAAAAAA=""#,
    #"{"$bytes":"AAAAAAAAAAAAAAAAAAAAAAAAAAA="}"#,
  ])
  func readsEverySupportedRecordFromTheOwnerPDS(_ artifactTagJSON: String) async throws {
    let responses = [
      response(
        collection: "sh.tangled.repo",
        value:
          """
          {"$type":"sh.tangled.repo","name":"core","knot":"knot.example","spindle":"spindle.example","repoDid":"\(repositoryDID)","createdAt":"2026-07-26T00:00:00Z"}
          """
      ),
      response(
        collection: "sh.tangled.repo.issue",
        value:
          """
          {"$type":"sh.tangled.repo.issue","repo":"\(repositoryDID)","title":"Fresh issue","body":"PDS body","createdAt":"2026-07-26T00:01:00Z"}
          """
      ),
      response(
        collection: "sh.tangled.repo.pull",
        value:
          """
          {"$type":"sh.tangled.repo.pull","title":"Fresh pull","rounds":[{"createdAt":"2026-07-26T00:02:00Z","patchBlob":{"$type":"blob","ref":{"$link":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a"},"mimeType":"application/gzip","size":42}}],"target":{"branch":"main","repo":"\(repositoryDID)"},"createdAt":"2026-07-26T00:02:00Z"}
          """
      ),
      response(
        collection: "sh.tangled.repo.artifact",
        value:
          """
          {"$type":"sh.tangled.repo.artifact","artifact":{"$type":"blob","ref":{"$link":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a"},"mimeType":"application/octet-stream","size":13},"createdAt":"2026-07-26T00:03:00Z","name":"release.zip","repoDid":"\(repositoryDID)","tag":\(artifactTagJSON)}
          """
      ),
    ]
    let transport = PDSRecordTransport(responses)
    let client = makeClient(transport: transport)

    let repository = try await client.repository(
      uri: uri(collection: "sh.tangled.repo")
    )
    let issue = try await client.issue(
      uri: uri(collection: "sh.tangled.repo.issue")
    )
    let pullRequest = try await client.pullRequest(
      uri: uri(collection: "sh.tangled.repo.pull")
    )
    let artifact = try await client.artifact(
      uri: uri(collection: "sh.tangled.repo.artifact")
    )

    #expect(repository.value.repoDID == repositoryDID)
    #expect(repository.value.spindle == "spindle.example")
    #expect(issue.value.title == "Fresh issue")
    #expect(issue.value.body == "PDS body")
    #expect(pullRequest.value.rounds.count == 1)
    #expect(
      pullRequest.value.rounds[0].patchBlob.cid
        == "bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a"
    )
    #expect(artifact.value.repositoryDID == repositoryDID)
    #expect(artifact.value.tagObjectHash == String(repeating: "00", count: 20))

    let requests = await transport.recordedRequests()
    #expect(requests.count == 4)
    #expect(requests.allSatisfy { $0.url?.host == "pds.example" })
    #expect(requests.allSatisfy { $0.url?.path == "/base/xrpc/com.atproto.repo.getRecord" })
    #expect(query(named: "repo", request: requests[0]) == ownerDID)
    #expect(query(named: "collection", request: requests[0]) == "sh.tangled.repo")
    #expect(query(named: "rkey", request: requests[0]) == rkey)
  }

  @Test(arguments: [
    #"{"$bytes":"not base64"}"#,
    #"{"$bytes":"AA=="}"#,
  ])
  func rejectsInvalidArtifactTagBytes(_ artifactTagJSON: String) async {
    let transport = PDSRecordTransport([
      response(
        collection: "sh.tangled.repo.artifact",
        value:
          """
          {"$type":"sh.tangled.repo.artifact","artifact":{"$type":"blob","ref":{"$link":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a"},"mimeType":"application/octet-stream","size":13},"createdAt":"2026-07-26T00:03:00Z","name":"release.zip","repoDid":"\(repositoryDID)","tag":\(artifactTagJSON)}
          """
      )
    ])

    await #expect(throws: TangledError.self) {
      _ = try await makeClient(transport: transport).artifact(
        uri: uri(collection: "sh.tangled.repo.artifact")
      )
    }
  }

  @Test func listsRepositoryRecordsWithPagination() async throws {
    let transport = PDSRecordTransport([
      .init(
        statusCode: 200,
        body: Data(
          """
          {"cursor":"next-page","records":[{"uri":"\(uri(collection: "sh.tangled.repo"))","cid":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a","value":{"$type":"sh.tangled.repo","name":"core","knot":"knot.example","repoDid":"\(repositoryDID)","createdAt":"2026-07-26T00:00:00Z"}}]}
          """.utf8
        )
      )
    ])
    let client = makeClient(transport: transport)

    let page = try await client.repositories(
      ownerDID: ownerDID,
      cursor: "previous-page",
      limit: 25,
      reverse: true
    )

    #expect(page.items.count == 1)
    #expect(page.items[0].value.name == "core")
    #expect(page.cursor == "next-page")
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path == "/base/xrpc/com.atproto.repo.listRecords")
    #expect(query(named: "repo", request: request) == ownerDID)
    #expect(query(named: "collection", request: request) == "sh.tangled.repo")
    #expect(query(named: "cursor", request: request) == "previous-page")
    #expect(query(named: "limit", request: request) == "25")
    #expect(query(named: "reverse", request: request) == "true")
  }

  @Test func listsPullRequestsAndStatusesFromOwnerPDS() async throws {
    let pullURI = uri(collection: "sh.tangled.repo.pull")
    let statusURI = uri(collection: "sh.tangled.repo.pull.status")
    let transport = PDSRecordTransport([
      .init(
        statusCode: 200,
        body: Data(
          """
          {"cursor":"next-pull","records":[{"uri":"\(pullURI)","cid":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a","value":{"$type":"sh.tangled.repo.pull","title":"Fresh pull","rounds":[{"createdAt":"2026-07-26T00:02:00Z","patchBlob":{"$type":"blob","ref":{"$link":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a"},"mimeType":"application/gzip","size":42}}],"target":{"branch":"main","repo":"\(repositoryDID)"},"createdAt":"2026-07-26T00:02:00Z"}}]}
          """.utf8
        )
      ),
      .init(
        statusCode: 200,
        body: Data(
          """
          {"cursor":"next-status","records":[{"uri":"\(statusURI)","cid":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a","value":{"$type":"sh.tangled.repo.pull.status","pull":"\(pullURI)","status":"sh.tangled.repo.pull.status.closed","createdAt":"2026-07-26T00:03:00Z"}}]}
          """.utf8
        )
      ),
    ])
    let client = makeClient(transport: transport)

    let pulls = try await client.pullRequests(
      ownerDID: ownerDID,
      cursor: "pull-cursor",
      limit: 25,
      reverse: true
    )
    let statuses = try await client.pullRequestStatuses(
      ownerDID: ownerDID,
      cursor: "status-cursor",
      limit: 10
    )

    #expect(pulls.cursor == "next-pull")
    #expect(pulls.items.first?.value.title == "Fresh pull")
    #expect(statuses.cursor == "next-status")
    #expect(statuses.items.first?.value.pullRequestURI == pullURI)
    #expect(statuses.items.first?.value.status == .closed)

    let requests = await transport.recordedRequests()
    #expect(query(named: "collection", request: requests[0]) == "sh.tangled.repo.pull")
    #expect(query(named: "cursor", request: requests[0]) == "pull-cursor")
    #expect(query(named: "reverse", request: requests[0]) == "true")
    #expect(
      query(named: "collection", request: requests[1])
        == "sh.tangled.repo.pull.status"
    )
    #expect(query(named: "cursor", request: requests[1]) == "status-cursor")
  }

  @Test func repositoryListingRejectsInvalidInputsBeforeResolution() async {
    let transport = PDSRecordTransport([])
    let resolver = PDSRecordResolver(document: nil)
    let client = PDSRecordClient(resolver: resolver, transport: transport)

    await #expect(throws: TangledError.self) {
      _ = try await client.repositories(ownerDID: "invalid")
    }
    await #expect(throws: TangledError.self) {
      _ = try await client.repositories(ownerDID: ownerDID, limit: 0)
    }
    await #expect(throws: TangledError.self) {
      _ = try await client.repositories(ownerDID: ownerDID, limit: 101)
    }
    await #expect(throws: TangledError.self) {
      _ = try await client.pullRequests(ownerDID: ownerDID, limit: 0)
    }
    await #expect(throws: TangledError.self) {
      _ = try await client.pullRequestStatuses(ownerDID: "invalid")
    }
    #expect(await resolver.resolutionCount() == 0)
    #expect(await transport.recordedRequests().isEmpty)
  }

  @Test func repositoryListingRejectsMismatchedRecordMetadata() async {
    let wrongOwner = PDSRecordTransport([
      .init(
        statusCode: 200,
        body: Data(
          """
          {"records":[{"uri":"at://did:plc:other/sh.tangled.repo/\(rkey)","cid":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a","value":{"$type":"sh.tangled.repo","name":"core","knot":"knot.example","createdAt":"2026-07-26T00:00:00Z"}}]}
          """.utf8
        )
      )
    ])
    let wrongType = PDSRecordTransport([
      .init(
        statusCode: 200,
        body: Data(
          """
          {"records":[{"uri":"\(uri(collection: "sh.tangled.repo"))","cid":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a","value":{"$type":"sh.tangled.repo.issue","repo":"\(repositoryDID)","title":"Issue","createdAt":"2026-07-26T00:00:00Z"}}]}
          """.utf8
        )
      )
    ])

    await #expect(throws: TangledError.self) {
      _ = try await makeClient(transport: wrongOwner).repositories(ownerDID: ownerDID)
    }
    await #expect(throws: TangledError.self) {
      _ = try await makeClient(transport: wrongType).repositories(ownerDID: ownerDID)
    }
  }

  @Test func rejectsInvalidRecordURIsBeforeResolutionOrTransport() async {
    let transport = PDSRecordTransport([])
    let resolver = PDSRecordResolver(document: nil)
    let client = PDSRecordClient(resolver: resolver, transport: transport)
    let invalid = [
      "not-an-at-uri",
      "at://owner.example/sh.tangled.repo/\(rkey)",
      "at://\(ownerDID)/sh.tangled.repo.issue/\(rkey)",
      "at://\(ownerDID)/sh.tangled.repo",
      "at://\(ownerDID)/sh.tangled.repo/\(rkey)#fragment",
    ]

    for uri in invalid {
      await #expect(throws: TangledError.self) {
        _ = try await client.repository(uri: uri)
      }
    }
    #expect(await resolver.resolutionCount() == 0)
    #expect(await transport.recordedRequests().isEmpty)
  }

  @Test func mapsRecordNotFoundWithoutDecodingARecord() async {
    let transport = PDSRecordTransport([
      .init(
        statusCode: 400,
        body: Data(#"{"error":"RecordNotFound","message":"missing"}"#.utf8)
      )
    ])
    let client = makeClient(transport: transport)

    do {
      _ = try await client.issue(uri: uri(collection: "sh.tangled.repo.issue"))
      Issue.record("Expected notFound")
    } catch TangledError.notFound(let message) {
      #expect(message == "missing")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func mapsNetworkAndServiceFailures() async {
    let networkClient = makeClient(transport: PDSRecordTransport([]))
    let unavailableClient = makeClient(
      transport: PDSRecordTransport([
        .init(
          statusCode: 503,
          body: Data(#"{"error":"Unavailable","message":"try later"}"#.utf8)
        )
      ])
    )

    do {
      _ = try await networkClient.repository(uri: uri(collection: "sh.tangled.repo"))
      Issue.record("Expected network error")
    } catch TangledError.network(let error) {
      #expect(error.code == .cannotConnectToHost)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    do {
      _ = try await unavailableClient.repository(uri: uri(collection: "sh.tangled.repo"))
      Issue.record("Expected serviceUnavailable")
    } catch TangledError.serviceUnavailable(let message) {
      #expect(message == "try later")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func reportsDecodingFailureRatherThanUnknownForMalformedKnownType() async {
    let listTransport = PDSRecordTransport([
      .init(
        statusCode: 200,
        body: Data(
          """
          {"records":[{"uri":"\(uri(collection: "sh.tangled.repo"))","cid":"bafkreidie4e7g2mr7u4rbvzuhzrgjxkvcc7qeac7uzidusdy74lvgb2r3a","value":{"$type":"sh.tangled.repo","knot":123,"createdAt":"2026-07-26T00:00:00Z"}}]}
          """.utf8
        )
      )
    ])
    let getTransport = PDSRecordTransport([
      response(
        collection: "sh.tangled.repo",
        value:
          """
          {"$type":"sh.tangled.repo","knot":123,"createdAt":"2026-07-26T00:00:00Z"}
          """
      )
    ])

    do {
      _ = try await makeClient(transport: listTransport).repositories(ownerDID: ownerDID)
      Issue.record("Expected decoding failure from list path")
    } catch TangledError.upstreamFailed(let message) {
      Issue.record(
        "Should not surface as upstreamFailed(record type unknown …): \(message ?? "")"
      )
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Issue.record("Unexpected error from list path: \(error)")
    }

    do {
      _ = try await makeClient(transport: getTransport).repository(
        uri: uri(collection: "sh.tangled.repo")
      )
      Issue.record("Expected decoding failure from getRecord path")
    } catch TangledError.upstreamFailed(let message) {
      Issue.record(
        "Should not surface as upstreamFailed(record type unknown …): \(message ?? "")"
      )
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Issue.record("Unexpected error from getRecord path: \(error)")
    }
  }

  @Test func rejectsMismatchedReturnedURIAndRecordType() async {
    let wrongURI = PDSRecordTransport([
      response(
        collection: "sh.tangled.repo.issue",
        returnedRkey: "different",
        value:
          """
          {"$type":"sh.tangled.repo.issue","repo":"\(repositoryDID)","title":"Issue","createdAt":"2026-07-26T00:00:00Z"}
          """
      )
    ])
    let wrongType = PDSRecordTransport([
      response(
        collection: "sh.tangled.repo.issue",
        value:
          """
          {"$type":"sh.tangled.repo.pull","title":"Pull","rounds":[],"target":{"branch":"main","repo":"\(repositoryDID)"},"createdAt":"2026-07-26T00:00:00Z"}
          """
      )
    ])

    await #expect(throws: TangledError.self) {
      _ = try await makeClient(transport: wrongURI).issue(
        uri: uri(collection: "sh.tangled.repo.issue")
      )
    }
    await #expect(throws: TangledError.self) {
      _ = try await makeClient(transport: wrongType).issue(
        uri: uri(collection: "sh.tangled.repo.issue")
      )
    }
  }

  @Test func rejectsMissingOrMismatchedDIDDocuments() async {
    let transport = PDSRecordTransport([])
    let missing = PDSRecordClient(
      resolver: PDSRecordResolver(document: nil),
      transport: transport
    )
    let mismatched = PDSRecordClient(
      resolver: PDSRecordResolver(document: document(did: "did:plc:other")),
      transport: transport
    )

    await #expect(throws: TangledError.self) {
      _ = try await missing.repository(uri: uri(collection: "sh.tangled.repo"))
    }
    await #expect(throws: TangledError.self) {
      _ = try await mismatched.repository(uri: uri(collection: "sh.tangled.repo"))
    }
    #expect(await transport.recordedRequests().isEmpty)
  }
}

extension PDSRecordClientTests {
  fileprivate func makeClient(transport: PDSRecordTransport) -> PDSRecordClient {
    PDSRecordClient(
      resolver: PDSRecordResolver(document: document(did: ownerDID)),
      transport: transport
    )
  }

  fileprivate func document(did: String) -> DIDDocument {
    DIDDocument(
      context: ["https://www.w3.org/ns/did/v1"],
      did: FormatString(rawValue: did),
      service: [
        .init(
          id: "#atproto_pds",
          type: "AtprotoPersonalDataServer",
          serviceEndpoint: "https://pds.example/base"
        )
      ]
    )
  }

  fileprivate func uri(collection: String) -> String {
    "at://\(ownerDID)/\(collection)/\(rkey)"
  }

  fileprivate func response(
    collection: String,
    returnedRkey: String? = nil,
    value: String
  ) -> PDSRecordTransport.Response {
    .init(
      statusCode: 200,
      body: Data(
        """
        {"uri":"at://\(ownerDID)/\(collection)/\(returnedRkey ?? rkey)","cid":"bafyfresh","value":\(value)}
        """.utf8
      )
    )
  }

  fileprivate func query(named name: String, request: URLRequest) -> String? {
    request.url.flatMap {
      URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == name }?.value
    }
  }
}

private actor PDSRecordResolver: ATPResolver {
  private let document: DIDDocument?
  private var count = 0

  init(document: DIDDocument?) {
    self.document = document
  }

  func resolve(handle: Handle) async throws -> DID? {
    nil
  }

  func resolve(did: DID) async throws -> DIDDocument? {
    count += 1
    return document
  }

  func resolutionCount() -> Int {
    count
  }
}

private actor PDSRecordTransport: HTTPTransport {
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
