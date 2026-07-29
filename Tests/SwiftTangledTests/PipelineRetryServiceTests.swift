import Testing

@testable import SwiftTangled

@Suite struct PipelineRetryServiceTests {
  @Test func retriesEveryWorkflowAndPreservesManualContext() async throws {
    let capture = RetryCapture()
    let pipeline = makePipeline(
      trigger: .manual(
        PipelineManualTrigger(
          sha: commit,
          ref: "refs/heads/main",
          sourceRepositoryDID: "did:plc:source",
          inputs: [.init(key: "configuration", value: "release")]
        )
      )
    )
    let service = makeService(pipeline: pipeline, capture: capture)

    let result = try await service.retry(
      pipelineID: "3mrlprkttms22",
      repositoryDID: "did:plc:repository"
    )

    #expect(
      result == "at://did:plc:spindle/sh.tangled.ci.pipeline/3mretrypipeline"
    )
    let request = try #require(await capture.request)
    #expect(request.repositoryDID == "did:plc:repository")
    #expect(request.workflows == ["build.yml", "test.yml"])
    #expect(request.token == "service-token")
    #expect(await capture.auth == .init(audience: "did:web:spindle.example", lxm: "sh.tangled.ci.triggerPipeline"))
    #expect(request.trigger == pipeline.trigger)
  }

  @Test func retriesOneWorkflowAndConvertsPushToManual() async throws {
    let capture = RetryCapture()
    let service = makeService(
      pipeline: makePipeline(
        trigger: .push(PipelinePushTrigger(ref: "refs/heads/main", newSHA: commit, oldSHA: commit)),
        sourceRepositoryDID: "did:plc:fork"
      ),
      capture: capture
    )

    _ = try await service.retry(
      pipelineID: "3mrlprkttms22",
      repositoryDID: "did:plc:repository",
      workflow: " test.yml "
    )

    let request = try #require(await capture.request)
    #expect(request.workflows == ["test.yml"])
    #expect(
      request.trigger
        == .manual(PipelineManualTrigger(sha: commit, sourceRepositoryDID: "did:plc:fork"))
    )
  }

  @Test func rejectsMissingWorkflowBeforeAuthentication() async {
    let capture = RetryCapture()
    let service = makeService(
      pipeline: makePipeline(
        trigger: .manual(PipelineManualTrigger(sha: commit))
      ),
      capture: capture
    )

    await #expect(throws: TangledError.self) {
      _ = try await service.retry(
        pipelineID: "3mrlprkttms22",
        repositoryDID: "did:plc:repository",
        workflow: "missing.yml"
      )
    }
    #expect(await capture.auth == nil)
    #expect(await capture.request == nil)
  }
}

private let commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

private func makePipeline(
  trigger: PipelineTrigger,
  sourceRepositoryDID: String? = nil
) -> Pipeline {
  Pipeline(
    id: "3mrlprkttms22",
    repositoryDID: "did:plc:repository",
    sourceRepositoryDID: sourceRepositoryDID,
    commit: commit,
    trigger: trigger,
    workflows: [
      PipelineWorkflow(id: "build.yml", name: "build.yml", status: .success),
      PipelineWorkflow(id: "test.yml", name: "test.yml", status: .failed),
    ]
  )
}

private func makeService(
  pipeline: Pipeline,
  capture: RetryCapture
) -> PipelineRetryService {
  PipelineRetryService(
    dependencies: PipelineRetryDependencies(
      pipeline: { _ in pipeline },
      serviceAuthToken: { audience, lxm in
        await capture.recordAuth(audience: audience, lxm: lxm)
        return "service-token"
      },
      trigger: { repositoryDID, trigger, workflows, token in
        await capture.recordRequest(
          repositoryDID: repositoryDID,
          trigger: trigger,
          workflows: workflows,
          token: token
        )
        return "at://did:plc:spindle/sh.tangled.ci.pipeline/3mretrypipeline"
      },
      serviceAudience: { "did:web:spindle.example" }
    )
  )
}

private actor RetryCapture {
  struct Auth: Equatable {
    let audience: String
    let lxm: String
  }

  struct Request: Equatable {
    let repositoryDID: String
    let trigger: PipelineTrigger
    let workflows: [String]
    let token: String
  }

  private(set) var auth: Auth?
  private(set) var request: Request?

  func recordAuth(audience: String, lxm: String) {
    auth = Auth(audience: audience, lxm: lxm)
  }

  func recordRequest(
    repositoryDID: String,
    trigger: PipelineTrigger,
    workflows: [String],
    token: String
  ) {
    request = Request(
      repositoryDID: repositoryDID,
      trigger: trigger,
      workflows: workflows,
      token: token
    )
  }
}
