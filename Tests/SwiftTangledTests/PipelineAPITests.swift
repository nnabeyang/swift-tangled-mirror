import Foundation
import SwiftAtproto
import Testing
import TangledLexicons

@testable import SwiftTangled

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite struct PipelineAPITests {
  @Test func pipelineTerminalAndSuccessStateUsesEveryWorkflow() {
    #expect(!PipelineWorkflowStatus.pending.isTerminal)
    #expect(!PipelineWorkflowStatus.running.isTerminal)
    #expect(PipelineWorkflowStatus.success.isTerminal)
    #expect(PipelineWorkflowStatus.failed.isTerminal)
    #expect(PipelineWorkflowStatus.timeout.isTerminal)
    #expect(PipelineWorkflowStatus.cancelled.isTerminal)
    #expect(PipelineWorkflowStatus.success.isSuccessful)
    #expect(!PipelineWorkflowStatus.failed.isSuccessful)

    #expect(!pipeline(workflows: []).isTerminal)
    #expect(
      !pipeline(workflows: [
        workflow(.success),
        workflow(.running),
      ]).isTerminal
    )
    #expect(
      pipeline(workflows: [
        workflow(.success),
        workflow(.success),
      ]).isSuccessful
    )
    let failed = pipeline(workflows: [
      workflow(.success),
      workflow(.failed),
    ])
    #expect(failed.isTerminal)
    #expect(!failed.isSuccessful)
  }

  @Test func queryPipelinesMapsModelsAndEncodesFilters() async throws {
    let transport = PipelineTransport([
      .init(statusCode: 200, body: try fixture("pipeline-page"))
    ])
    let client = try SpindleClient(
      spindle: "spindle.tangled.sh",
      transport: transport,
      retryPolicy: BobbinRetryPolicy(maxAttempts: 1)
    )

    let page = try await client.pipelines(
      repositoryDID: "did:plc:repository",
      commits: [
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "cccccccccccccccccccccccccccccccccccccccc",
      ],
      triggerKinds: [.push, .pullRequest],
      cursor: "previous-page",
      limit: 25
    )

    #expect(client.baseURL.absoluteString == "https://spindle.tangled.sh")
    #expect(page.cursor == "1784698509603192451")
    #expect(page.total == 4879)
    #expect(page.pipelines.count == 3)
    #expect(page.pipelines[0].id == "3mr7m2f6ger22")
    #expect(page.pipelines[0].repositoryDID == "did:plc:repository")
    #expect(page.pipelines[0].createdAt?.typed != nil)
    #expect(page.pipelines[0].workflows[0].status == .success)
    #expect(page.pipelines[0].workflows[1].error == "User step error: exited with code 1")
    guard case .push(let push) = page.pipelines[0].trigger else {
      Issue.record("Expected push trigger")
      return
    }
    #expect(push.ref == "refs/heads/main")
    #expect(push.oldSHA == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

    guard case .pullRequest(let pullRequest) = page.pipelines[1].trigger else {
      Issue.record("Expected pull request trigger")
      return
    }
    #expect(pullRequest.sourceRepositoryDID == "did:plc:fork")
    #expect(
      pullRequest.pullRequestURI
        == "at://did:plc:author/sh.tangled.repo.pull/3mr7m2f6ger25"
    )

    guard case .manual(let manual) = page.pipelines[2].trigger else {
      Issue.record("Expected manual trigger")
      return
    }
    #expect(manual.inputs == [.init(key: "configuration", value: "release")])
    #expect(page.pipelines[2].workflows[0].status == .cancelled)

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.lastPathComponent == "sh.tangled.ci.queryPipelines")
    #expect(queryValues(named: "repo", in: request) == ["did:plc:repository"])
    #expect(
      queryValues(named: "commits", in: request) == [
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "cccccccccccccccccccccccccccccccccccccccc",
      ]
    )
    #expect(queryValues(named: "kinds", in: request) == ["push", "pull_request"])
    #expect(queryValues(named: "cursor", in: request) == ["previous-page"])
    #expect(queryValues(named: "limit", in: request) == ["25"])
  }

  @Test func getPipelineUsesGeneratedQueryAndMapsPipeline() async throws {
    let transport = PipelineTransport([
      .init(statusCode: 200, body: try fixture("pipeline"))
    ])
    let client = makeClient(transport: transport)

    let pipeline = try await client.pipeline(id: "3mr7m2f6ger22")

    #expect(pipeline.commit == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(
      pipeline.workflows == [
        PipelineWorkflow(
          id: "build.yml",
          name: "build.yml",
          status: .success,
          startedAt: FormatString<Date>(rawValue: "2026-07-22T08:35:10+03:00"),
          finishedAt: FormatString<Date>(rawValue: "2026-07-22T08:36:10+03:00")
        )
      ])

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.lastPathComponent == "sh.tangled.ci.getPipeline")
    #expect(queryValues(named: "pipeline", in: request) == ["3mr7m2f6ger22"])
  }

  @Test func triggerPipelineUsesAuthenticatedGeneratedProcedure() async throws {
    let transport = PipelineTransport([
      .init(
        statusCode: 200,
        body: Data(
          #"{"pipeline":"at://did:web:spindle.example/sh.tangled.pipeline/retry-pipeline"}"#.utf8
        )
      )
    ])
    let client = makeClient(transport: transport)

    let result = try await client.triggerPipeline(
      repositoryDID: "did:plc:repository",
      trigger: .manual(
        PipelineManualTrigger(
          sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          ref: "refs/heads/main",
          sourceRepositoryDID: "did:plc:source",
          inputs: [.init(key: "configuration", value: "release")]
        )
      ),
      workflows: ["verify.yml"],
      token: "service-token"
    )

    #expect(
      result == "at://did:web:spindle.example/sh.tangled.pipeline/retry-pipeline"
    )
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.lastPathComponent == "sh.tangled.ci.triggerPipeline")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer service-token")
    let body = try #require(request.httpBody)
    let object = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(object["repo"] as? String == "did:plc:repository")
    #expect(object["workflows"] as? [String] == ["verify.yml"])
    let trigger = try #require(object["trigger"] as? [String: Any])
    #expect(trigger["$type"] as? String == "sh.tangled.ci.trigger#manual")
    #expect(trigger["sha"] as? String == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(trigger["sourceRepo"] as? String == "did:plc:source")
  }

  @Test func triggerPipelineOmitsUnspecifiedWorkflows() async throws {
    let transport = PipelineTransport([
      .init(
        statusCode: 200,
        body: Data(
          #"{"pipeline":"at://did:web:spindle.example/sh.tangled.ci.pipeline/manual-pipeline"}"#.utf8
        )
      )
    ])
    let client = makeClient(transport: transport)

    _ = try await client.triggerPipeline(
      repositoryDID: "did:plc:repository",
      trigger: .manual(
        PipelineManualTrigger(
          sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
      ),
      workflows: nil,
      token: "service-token"
    )

    let request = try #require(await transport.recordedRequests().first)
    let body = try #require(request.httpBody)
    let object = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(object["workflows"] == nil)
  }

  @Test func cancelPipelineUsesAuthenticatedGeneratedProcedure() async throws {
    let transport = PipelineTransport([
      .init(statusCode: 200, body: Data())
    ])
    let client = makeClient(transport: transport)

    try await client.cancelPipeline(
      repositoryDID: "did:plc:repository",
      pipelineID: "3mr7m2f6ger22",
      workflows: ["verify.yml"],
      token: "service-token"
    )

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.lastPathComponent == "sh.tangled.ci.cancelPipeline")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer service-token")
    let body = try #require(request.httpBody)
    let object = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(object["repo"] as? String == "did:plc:repository")
    #expect(object["pipeline"] as? String == "3mr7m2f6ger22")
    #expect(object["workflows"] as? [String] == ["verify.yml"])
  }

  @Test func cancelPipelineOmitsUnspecifiedWorkflowsAndPreservesErrors() async throws {
    let transport = PipelineTransport([
      .init(statusCode: 200, body: Data()),
      .init(
        statusCode: 400,
        body: Data(
          #"{"error":"AccessControl","message":"actor cannot modify repository"}"#.utf8
        )
      ),
    ])
    let client = makeClient(transport: transport)

    try await client.cancelPipeline(
      repositoryDID: "did:plc:repository",
      pipelineID: "3mr7m2f6ger22",
      workflows: nil,
      token: "service-token"
    )
    let request = try #require(await transport.recordedRequests().first)
    let body = try #require(request.httpBody)
    let object = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(object["workflows"] == nil)

    do {
      try await client.cancelPipeline(
        repositoryDID: "did:plc:repository",
        pipelineID: "3mr7m2f6ger22",
        workflows: ["verify.yml"],
        token: "service-token"
      )
      Issue.record("Expected AccessControl")
    } catch Sh.Tangled.CiCancelPipeline.Error.unexpected(let error, let message) {
      #expect(error == "AccessControl")
      #expect(message == "actor cannot modify repository")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func rawValueModelsAndUnknownTriggerRoundTrip() throws {
    let unknownStatus = try JSONDecoder().decode(
      PipelineWorkflowStatus.self,
      from: Data(#""queued""#.utf8)
    )
    let unknownKind = PipelineTriggerKind(rawValue: "schedule")
    let triggerData = Data(
      #"{"$type":"sh.tangled.ci.trigger#schedule","cron":"0 0 * * *"}"#.utf8
    )
    let trigger = try JSONDecoder().decode(PipelineTrigger.self, from: triggerData)

    #expect(unknownStatus.rawValue == "queued")
    #expect(
      String(decoding: try JSONEncoder().encode(unknownKind), as: UTF8.self)
        == #""schedule""#
    )
    #expect(
      trigger
        == .unknown(
          type: "sh.tangled.ci.trigger#schedule",
          fields: ["cron": .string("0 0 * * *")]
        )
    )
    #expect(
      try JSONDecoder().decode(
        PipelineTrigger.self,
        from: JSONEncoder().encode(trigger)
      ) == trigger)

    let manual = try JSONDecoder().decode(
      PipelineTrigger.self,
      from: Data(
        #"{"$type":"sh.tangled.ci.trigger#manual","sha":"dddddddddddddddddddddddddddddddddddddddd"}"#
          .utf8
      )
    )
    #expect(
      manual
        == .manual(
          PipelineManualTrigger(sha: "dddddddddddddddddddddddddddddddddddddddd")
        )
    )
  }

  @Test func invalidInputsFailBeforeNetworkRequest() async {
    let transport = PipelineTransport([])
    let client = makeClient(transport: transport)

    await expectInvalidRequest {
      _ = try await client.pipelines(repositoryDID: "")
    }
    await expectInvalidRequest {
      _ = try await client.pipelines(repositoryDID: "did:plc:repository", commits: [""])
    }
    await expectInvalidRequest {
      _ = try await client.pipelines(repositoryDID: "did:plc:repository", limit: 0)
    }
    await expectInvalidRequest {
      _ = try await client.pipelines(repositoryDID: "did:plc:repository", limit: 251)
    }
    await expectInvalidRequest {
      _ = try await client.pipelines(
        repositoryDID: "did:plc:repository",
        triggerKinds: [.init(rawValue: "schedule")]
      )
    }
    await expectInvalidRequest {
      _ = try await client.pipeline(id: "not-a-tid")
    }
    await expectInvalidRequest {
      try await client.cancelPipeline(
        repositoryDID: "not-a-did",
        pipelineID: "3mr7m2f6ger22",
        workflows: nil,
        token: "service-token"
      )
    }
    await expectInvalidRequest {
      try await client.cancelPipeline(
        repositoryDID: "did:plc:repository",
        pipelineID: "not-a-tid",
        workflows: nil,
        token: "service-token"
      )
    }
    await expectInvalidRequest {
      try await client.cancelPipeline(
        repositoryDID: "did:plc:repository",
        pipelineID: "3mr7m2f6ger22",
        workflows: [""],
        token: "service-token"
      )
    }
    #expect(await transport.requestCount() == 0)
  }

  @Test func invalidSpindleAndResponsesStayTyped() async throws {
    do {
      _ = try SpindleClient(spindle: "ftp://spindle.example")
      Issue.record("Expected invalidRequest")
    } catch TangledError.invalidRequest {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let transport = PipelineTransport([
      .init(
        statusCode: 404,
        body: Data(#"{"error":"PipelineNotFound","message":"pipeline not found"}"#.utf8)
      ),
      .init(statusCode: 200, body: Data(#"{"id":"3mr7m2f6ger22"}"#.utf8)),
    ])
    let client = makeClient(transport: transport)

    do {
      _ = try await client.pipeline(id: "3mr7m2f6ger22")
      Issue.record("Expected notFound")
    } catch Sh.Tangled.CiGetPipeline.Error.pipelinenotfound(let message) {
      #expect(message == "pipeline not found")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    do {
      _ = try await client.pipeline(id: "3mr7m2f6ger22")
      Issue.record("Expected decoding error")
    } catch TangledError.decoding {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

extension PipelineAPITests {
  fileprivate func pipeline(workflows: [PipelineWorkflow]) -> Pipeline {
    Pipeline(
      id: "3mr7m2f6ger22",
      commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      trigger: .push(
        PipelinePushTrigger(
          ref: "refs/heads/main",
          newSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          oldSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )
      ),
      workflows: workflows
    )
  }

  fileprivate func workflow(_ status: PipelineWorkflowStatus) -> PipelineWorkflow {
    PipelineWorkflow(id: UUID().uuidString, name: "verify.yml", status: status)
  }

  fileprivate func makeClient(transport: PipelineTransport) -> SpindleClient {
    SpindleClient(
      baseURL: URL(string: "https://spindle.example/base")!,
      transport: transport,
      retryPolicy: BobbinRetryPolicy(maxAttempts: 1)
    )
  }

  fileprivate func fixture(_ name: String) throws -> Data {
    guard
      let url = Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
      )
    else {
      throw PipelineFixtureError.missing(name)
    }
    return try Data(contentsOf: url)
  }

  fileprivate func queryValues(named name: String, in request: URLRequest) -> [String] {
    guard let url = request.url else { return [] }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .filter { $0.name == name }
      .compactMap(\.value) ?? []
  }

  fileprivate func expectInvalidRequest(_ operation: () async throws -> Void) async {
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

private enum PipelineFixtureError: Error {
  case missing(String)
}

private actor PipelineTransport: HTTPTransport {
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

  func recordedRequests() -> [URLRequest] {
    requests
  }

  func requestCount() -> Int {
    requests.count
  }
}
