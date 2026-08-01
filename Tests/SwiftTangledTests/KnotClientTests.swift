import Foundation
import SwiftTangled
import TangledLexicons
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct KnotClientTests {
  @Test func collaboratorAPIsUseKnotCapabilityAndAuthenticatedProcedures() async throws {
    let versionTransport = KnotTransport(
      statusCode: 200,
      body: Data(#"{"version":"1.16.0","capabilities":["knot-acl"]}"#.utf8)
    )
    let capabilities = try await KnotClient(transport: versionTransport).capabilities(
      knot: "knot.example"
    )
    #expect(capabilities == ["knot-acl"])
    #expect(
      await versionTransport.request()?.url?.absoluteString
        == "https://knot.example/xrpc/sh.tangled.knot.version"
    )

    let listTransport = KnotTransport(
      statusCode: 200,
      body: Data(
        #"{"items":[{"subject":"did:plc:collaborator","addedBy":"did:plc:owner","createdAt":"2026-08-01T00:00:00Z"}],"cursor":"next"}"#.utf8
      )
    )
    let page = try await KnotClient(transport: listTransport).collaborators(
      knot: "knot.example",
      repositoryDID: "did:plc:repository",
      cursor: "previous",
      limit: 25,
      order: .ascending
    )
    #expect(page.items.first?.subjectDID == "did:plc:collaborator")
    #expect(page.cursor == "next")
    let listURL = try #require(await listTransport.request()?.url?.absoluteString)
    #expect(listURL.contains("subject=did%3Aplc%3Arepository"))
    #expect(listURL.contains("cursor=previous"))
    #expect(listURL.contains("limit=25"))
    #expect(listURL.contains("order=asc"))

    let addTransport = KnotTransport(statusCode: 200, body: Data("{}".utf8))
    try await KnotClient(transport: addTransport).addCollaborator(
      knot: "knot.example",
      token: "add-token",
      repositoryDID: "did:plc:repository",
      collaboratorDID: "did:plc:collaborator"
    )
    let addRequest = try #require(await addTransport.request())
    #expect(addRequest.url?.absoluteString == "https://knot.example/xrpc/sh.tangled.repo.addCollaborator")
    #expect(addRequest.value(forHTTPHeaderField: "Authorization") == "Bearer add-token")
    let addInput = try JSONDecoder().decode(
      Sh.Tangled.RepoAddCollaborator_Input.self,
      from: try #require(addRequest.httpBody)
    )
    #expect(addInput.repo.rawValue == "did:plc:repository")
    #expect(addInput.subject.rawValue == "did:plc:collaborator")

    let removeTransport = KnotTransport(statusCode: 200, body: Data("{}".utf8))
    try await KnotClient(transport: removeTransport).removeCollaborator(
      knot: "knot.example",
      token: "remove-token",
      repositoryDID: "did:plc:repository",
      collaboratorDID: "did:plc:collaborator"
    )
    let removeRequest = try #require(await removeTransport.request())
    #expect(removeRequest.url?.absoluteString == "https://knot.example/xrpc/sh.tangled.repo.removeCollaborator")
    #expect(removeRequest.value(forHTTPHeaderField: "Authorization") == "Bearer remove-token")
  }

  @Test func bobbinCollaboratorAPIsMapPagesAndCounts() async throws {
    let listTransport = KnotTransport(
      statusCode: 200,
      body: Data(
        #"{"items":[{"subject":"did:plc:collaborator","addedBy":"did:plc:owner","createdAt":"2026-08-01T00:00:00Z","uri":"at://did:plc:owner/sh.tangled.repo.collaborator/3abc"}],"cursor":"next"}"#.utf8
      )
    )
    let page = try await BobbinClient(
      baseURL: URL(string: "https://api.example")!,
      transport: listTransport,
      retryPolicy: .init(maxAttempts: 1)
    ).collaborators(repositoryDID: "did:plc:repository", limit: 10)
    #expect(page.items.first?.recordURI?.contains("collaborator") == true)
    #expect(page.cursor == "next")

    let countTransport = KnotTransport(
      statusCode: 200,
      body: Data(#"{"count":2,"distinctAuthors":1}"#.utf8)
    )
    let count = try await BobbinClient(
      baseURL: URL(string: "https://api.example")!,
      transport: countTransport,
      retryPolicy: .init(maxAttempts: 1)
    ).collaboratorCount(repositoryDID: "did:plc:repository")
    #expect(count == CountSummary(count: 2, distinctAuthors: 1))
  }

  @Test func repositoryLifecycleUsesAuthenticatedKnotProcedures() async throws {
    let createTransport = KnotTransport(
      statusCode: 200,
      body: Data(#"{"key":"zSigningKey","repoDid":"did:plc:repository"}"#.utf8)
    )
    let repositoryDID = try await KnotClient(transport: createTransport).createRepository(
      knot: "knot.example",
      token: "create-token",
      rkey: "example",
      name: "example",
      defaultBranch: "main",
      source: "https://example.com/source.git",
      repositoryDID: nil
    )
    #expect(repositoryDID == "did:plc:repository")
    let createRequest = try #require(await createTransport.request())
    #expect(createRequest.url?.absoluteString == "https://knot.example/xrpc/sh.tangled.repo.create")
    #expect(createRequest.value(forHTTPHeaderField: "Authorization") == "Bearer create-token")
    let createInput = try JSONDecoder().decode(
      Sh.Tangled.RepoCreate_Input.self,
      from: try #require(createRequest.httpBody)
    )
    #expect(createInput.rkey.rawValue == "example")
    #expect(createInput.defaultBranch == "main")
    #expect(createInput.source == "https://example.com/source.git")

    let deleteTransport = KnotTransport(statusCode: 200, body: Data("{}".utf8))
    try await KnotClient(transport: deleteTransport).deleteRepository(
      knot: "knot.example",
      token: "delete-token",
      ownerDID: "did:plc:owner",
      name: "example",
      rkey: "example"
    )
    let deleteRequest = try #require(await deleteTransport.request())
    #expect(deleteRequest.url?.absoluteString == "https://knot.example/xrpc/sh.tangled.repo.delete")
    #expect(deleteRequest.value(forHTTPHeaderField: "Authorization") == "Bearer delete-token")
    let deleteInput = try JSONDecoder().decode(
      Sh.Tangled.RepoDelete_Input.self,
      from: try #require(deleteRequest.httpBody)
    )
    #expect(deleteInput.did.rawValue == "did:plc:owner")
    #expect(deleteInput.name == "example")
    #expect(deleteInput.rkey.rawValue == "example")
    #expect(deleteInput.force == nil)
    let deleteBody = try #require(deleteRequest.httpBody)
    let deleteObject = try #require(
      JSONSerialization.jsonObject(with: deleteBody) as? [String: Any]
    )
    #expect(deleteObject["force"] == nil)
  }

  @Test func repositoryLifecycleRejectsInvalidRecordKeysBeforeRequest() async {
    let createTransport = KnotTransport(statusCode: 200, body: Data("{}".utf8))
    await #expect(throws: TangledError.self) {
      _ = try await KnotClient(transport: createTransport).createRepository(
        knot: "knot.example",
        token: "token",
        rkey: "invalid/key",
        name: "example",
        defaultBranch: "main"
      )
    }
    #expect(await createTransport.request() == nil)

    let deleteTransport = KnotTransport(statusCode: 200, body: Data("{}".utf8))
    await #expect(throws: TangledError.self) {
      try await KnotClient(transport: deleteTransport).deleteRepository(
        knot: "knot.example",
        token: "token",
        ownerDID: "did:plc:owner",
        name: "example",
        rkey: "invalid/key"
      )
    }
    #expect(await deleteTransport.request() == nil)
  }

  @Test func repositoryCreationRejectsMissingRepositoryDID() async {
    await #expect(throws: TangledError.self) {
      _ = try await KnotClient(
        transport: KnotTransport(statusCode: 200, body: Data("{}".utf8))
      ).createRepository(
        knot: "knot.example",
        token: "token",
        rkey: "example",
        name: "example",
        defaultBranch: "main"
      )
    }
  }

  @Test func mergeCheckUsesKnotProcedureAndMapsConflicts() async throws {
    let transport = KnotTransport(
      statusCode: 200,
      body: Data(
        """
        {"is_conflicted":true,"conflicts":[{"filename":"Sources/App.swift","reason":"content"}],"message":"resolve conflicts"}
        """.utf8
      )
    )
    let result = try await KnotClient(transport: transport).mergeCheck(
      knot: "knot.example",
      ownerDID: "did:plc:owner",
      repositoryName: "core",
      repositoryDID: "did:plc:repository",
      branch: "main",
      patch: "patch"
    )

    #expect(result.isConflicted)
    #expect(result.conflicts == [.init(filename: "Sources/App.swift", reason: "content")])
    let request = try #require(await transport.request())
    #expect(request.url?.absoluteString == "https://knot.example/xrpc/sh.tangled.repo.mergeCheck")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let body = try #require(request.httpBody)
    #expect(String(decoding: body, as: UTF8.self).contains("\"repo\":\"did:plc:repository\""))
  }

  @Test func mergeCheckFallsBackToMergeConflictMessageOn409() async throws {
    let transport = KnotTransport(statusCode: 409, body: Data("{}".utf8))
    do {
      _ = try await KnotClient(transport: transport).mergeCheck(
        knot: "knot.example",
        ownerDID: "did:plc:owner",
        repositoryName: "core",
        repositoryDID: "did:plc:repository",
        branch: "main",
        patch: "patch"
      )
      Testing.Issue.record("expected invalidRequest")
    } catch TangledError.invalidRequest(let message) {
      #expect(message == "merge conflict")
    } catch {
      Testing.Issue.record("unexpected error: \(error)")
    }
  }

  @Test func merge403IsForbiddenNotUnauthorized() async throws {
    let transport = KnotTransport(
      statusCode: 403,
      body: Data(#"{"error":"Forbidden","message":"not a maintainer"}"#.utf8)
    )
    do {
      try await KnotClient(transport: transport).merge(
        knot: "knot.example",
        token: "service-token",
        ownerDID: "did:plc:owner",
        repositoryName: "core",
        repositoryDID: "did:plc:repository",
        branch: "main",
        patch: "patch",
        commitMessage: "Merge title",
        commitBody: nil
      )
      Testing.Issue.record("expected forbidden")
    } catch TangledError.forbidden(let message) {
      #expect(message == "not a maintainer")
    } catch {
      Testing.Issue.record("unexpected error: \(error)")
    }
  }

  @Test func mergeMapsGatewayTimeoutToServiceUnavailable() async throws {
    let transport = KnotTransport(statusCode: 504, body: Data("{}".utf8))
    do {
      try await KnotClient(transport: transport).merge(
        knot: "knot.example",
        token: "service-token",
        ownerDID: "did:plc:owner",
        repositoryName: "core",
        repositoryDID: "did:plc:repository",
        branch: "main",
        patch: "patch",
        commitMessage: "Merge title",
        commitBody: nil
      )
      Testing.Issue.record("expected serviceUnavailable")
    } catch TangledError.serviceUnavailable {
      // Expected.
    } catch {
      Testing.Issue.record("unexpected error: \(error)")
    }
  }

  @Test func merge429PropagatesRateLimitWithParsedRetryAfter() async throws {
    let transport = KnotTransport(
      statusCode: 429,
      body: Data(#"{"error":"RateLimited","message":"slow down"}"#.utf8),
      headers: ["Retry-After": "90"]
    )
    do {
      try await KnotClient(transport: transport).merge(
        knot: "knot.example",
        token: "service-token",
        ownerDID: "did:plc:owner",
        repositoryName: "core",
        repositoryDID: "did:plc:repository",
        branch: "main",
        patch: "patch",
        commitMessage: "Merge title",
        commitBody: nil
      )
      Testing.Issue.record("expected rateLimited")
    } catch TangledError.rateLimited(let retryAfter, let message) {
      #expect(retryAfter == 90)
      #expect(message == "slow down")
    } catch {
      Testing.Issue.record("unexpected error: \(error)")
    }
  }

  @Test func merge429HandlesHTTPDateRetryAfter() async throws {
    let future = Date().addingTimeInterval(120)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    let httpDate = formatter.string(from: future)

    let transport = KnotTransport(
      statusCode: 429,
      body: Data("{}".utf8),
      headers: ["Retry-After": httpDate]
    )
    do {
      try await KnotClient(transport: transport).merge(
        knot: "knot.example",
        token: "service-token",
        ownerDID: "did:plc:owner",
        repositoryName: "core",
        repositoryDID: "did:plc:repository",
        branch: "main",
        patch: "patch",
        commitMessage: "Merge title",
        commitBody: nil
      )
      Testing.Issue.record("expected rateLimited")
    } catch TangledError.rateLimited(let retryAfter, _) {
      #expect(retryAfter != nil)
      #expect((retryAfter ?? 0) <= 121)  // upper bound guards against runaway parse
    } catch {
      Testing.Issue.record("unexpected error: \(error)")
    }
  }

  @Test func applicationErrorsPreserveCodeAndMessageSeparately() async throws {
    let both = KnotTransport(
      statusCode: 404,
      body: Data(#"{"error":"BlobNotFound","message":"blob is gone"}"#.utf8)
    )
    let onlyError = KnotTransport(
      statusCode: 404,
      body: Data(#"{"error":"BlobNotFound"}"#.utf8)
    )
    let onlyMessage = KnotTransport(
      statusCode: 404,
      body: Data(#"{"message":"blob is gone"}"#.utf8)
    )

    func mergeError(_ transport: KnotTransport) async -> (String?, String?) {
      do {
        try await KnotClient(transport: transport).merge(
          knot: "knot.example",
          token: "service-token",
          ownerDID: "did:plc:owner",
          repositoryName: "core",
          repositoryDID: "did:plc:repository",
          branch: "main",
          patch: "patch",
          commitMessage: "Merge title",
          commitBody: nil
        )
        Testing.Issue.record("expected an error")
        return (nil, nil)
      } catch let error as Sh.Tangled.RepoMerge.Error {
        return (error.error, error.message)
      } catch TangledError.notFound(let message) {
        return (nil, message)
      } catch {
        Testing.Issue.record("unexpected error: \(error)")
        return (nil, nil)
      }
    }

    let bothResult = await mergeError(both)
    #expect(bothResult.0 == "BlobNotFound")
    #expect(bothResult.1 == "blob is gone")
    let onlyErrorResult = await mergeError(onlyError)
    #expect(onlyErrorResult.0 == "BlobNotFound")
    #expect(onlyErrorResult.1 == nil)
    let onlyMessageResult = await mergeError(onlyMessage)
    #expect(onlyMessageResult.0 == nil)
    #expect(onlyMessageResult.1 == "blob is gone")
  }

  @Test func merge401IsUnauthorized() async throws {
    let transport = KnotTransport(
      statusCode: 401,
      body: Data(#"{"error":"Unauthorized","message":"expired token"}"#.utf8)
    )
    do {
      try await KnotClient(transport: transport).merge(
        knot: "knot.example",
        token: "service-token",
        ownerDID: "did:plc:owner",
        repositoryName: "core",
        repositoryDID: "did:plc:repository",
        branch: "main",
        patch: "patch",
        commitMessage: "Merge title",
        commitBody: nil
      )
      Testing.Issue.record("expected unauthorized")
    } catch TangledError.unauthorized {
      // Expected.
    } catch {
      Testing.Issue.record("unexpected error: \(error)")
    }
  }

  @Test func mergeSetsDeterministicJSONAcceptHeader() async throws {
    let transport = KnotTransport(statusCode: 200, body: Data("{}".utf8))
    try await KnotClient(transport: transport).merge(
      knot: "knot.example",
      token: "t",
      ownerDID: "did:plc:owner",
      repositoryName: "core",
      repositoryDID: "did:plc:repository",
      branch: "main",
      patch: "patch",
      commitMessage: "m",
      commitBody: nil
    )
    let request = try #require(await transport.request())
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
  }

  @Test func mergeSendsServiceToken() async throws {
    let transport = KnotTransport(statusCode: 200, body: Data("{}".utf8))
    try await KnotClient(transport: transport).merge(
      knot: "https://knot.example",
      token: "service-token",
      ownerDID: "did:plc:owner",
      repositoryName: "core",
      repositoryDID: "did:plc:repository",
      branch: "main",
      patch: "patch",
      commitMessage: "Merge title",
      commitBody: "Merge body"
    )

    let request = try #require(await transport.request())
    #expect(request.url?.absoluteString == "https://knot.example/xrpc/sh.tangled.repo.merge")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer service-token")
  }

  @Test func hiddenRefUsesServiceTokenAndReturnsExpectedReference() async throws {
    let transport = KnotTransport(
      statusCode: 200,
      body: Data(#"{"success":true}"#.utf8)
    )
    let reference = try await KnotClient(transport: transport).updateHiddenRef(
      knot: "knot.example",
      token: "service-token",
      repositoryURI: "at://did:plc:owner/sh.tangled.repo/example",
      sourceBranch: "feature",
      targetBranch: "main"
    )

    #expect(reference == "hidden/feature/main")
    let request = try #require(await transport.request())
    #expect(
      request.url?.absoluteString
        == "https://knot.example/xrpc/sh.tangled.repo.hiddenRef"
    )
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer service-token")
    let input = try JSONDecoder().decode(
      Sh.Tangled.RepoHiddenRef_Input.self,
      from: try #require(request.httpBody)
    )
    #expect(input.repo.rawValue == "at://did:plc:owner/sh.tangled.repo/example")
    #expect(input.forkRef == "feature")
    #expect(input.remoteRef == "main")
  }

  @Test func hiddenRefRejectsUnsuccessfulAndMismatchedResponses() async {
    for body in [
      Data(#"{"success":false,"error":"fetch failed"}"#.utf8),
      Data(#"{"success":true,"ref":"hidden/other/main"}"#.utf8),
    ] {
      await #expect(throws: TangledError.self) {
        _ = try await KnotClient(
          transport: KnotTransport(statusCode: 200, body: body)
        ).updateHiddenRef(
          knot: "knot.example",
          token: "service-token",
          repositoryURI: "at://did:plc:owner/sh.tangled.repo/example",
          sourceBranch: "feature",
          targetBranch: "main"
        )
      }
    }
  }

  @Test func compareReadsFormatPatchFromForkKnot() async throws {
    let transport = KnotTransport(
      statusCode: 200,
      body: Data(
        #"{"rev1":"aaaaaaaa","rev2":"bbbbbbbb","patch":"From bbbbbbbb Mon Sep 17 00:00:00 2001\n"}"#
          .utf8
      )
    )
    let comparison = try await KnotClient(transport: transport).compare(
      knot: "knot.example",
      repositoryDID: "did:plc:repository",
      baseRevision: "hidden/feature/main",
      headRevision: "feature"
    )

    #expect(comparison.baseRevision == "aaaaaaaa")
    #expect(comparison.headRevision == "bbbbbbbb")
    #expect(comparison.patch.hasPrefix("From bbbbbbbb"))
    let request = try #require(await transport.request())
    let url = try #require(request.url)
    let components = try #require(
      URLComponents(url: url, resolvingAgainstBaseURL: false)
    )
    #expect(components.path == "/xrpc/sh.tangled.repo.compare")
    #expect(
      Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).map {
          ($0.name, $0.value)
        })
        == [
          "repo": "did:plc:repository",
          "rev1": "hidden/feature/main",
          "rev2": "feature",
        ]
    )
  }
}

private actor KnotTransport: HTTPTransport {
  private let statusCode: Int
  private let body: Data
  private let headers: [String: String]
  private var recordedRequest: URLRequest?

  init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
    self.statusCode = statusCode
    self.body = body
    self.headers = headers
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    recordedRequest = request
    return (
      body,
      HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )!
    )
  }

  func request() -> URLRequest? {
    recordedRequest
  }
}
