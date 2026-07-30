import Testing

@testable import SwiftTangled

@Suite struct PipelineCancelServiceTests {
  @Test func cancelsEveryActiveWorkflowWithServiceAuthentication() async throws {
    let capture = CancelCapture()
    let service = makeCancelService(
      pipeline: cancelPipeline([
        cancelWorkflow("build.yml", .success),
        cancelWorkflow("test.yml", .running),
        cancelWorkflow("deploy.yml", .pending),
      ]),
      capture: capture
    )

    let result = try await service.cancel(
      pipelineID: cancelPipelineID,
      repositoryDID: "did:plc:repository"
    )

    #expect(
      result
        == PipelineCancellation(
          pipeline: cancelPipelineID,
          workflows: ["test.yml", "deploy.yml"]
        )
    )
    #expect(
      await capture.auth
        == .init(
          audience: "did:web:spindle.example",
          lxm: "sh.tangled.ci.cancelPipeline"
        )
    )
    #expect(
      await capture.request
        == .init(
          repositoryDID: "did:plc:repository",
          pipelineID: cancelPipelineID,
          workflows: ["test.yml", "deploy.yml"],
          token: "service-token"
        )
    )
  }

  @Test func normalizesSelectionAndSkipsFinishedWorkflows() async throws {
    let capture = CancelCapture()
    let service = makeCancelService(
      pipeline: cancelPipeline([
        cancelWorkflow("build.yml", .success),
        cancelWorkflow("test.yml", .running),
      ]),
      capture: capture
    )

    let result = try await service.cancel(
      pipelineID: cancelPipelineID,
      repositoryDID: "did:plc:repository",
      workflows: [" build.yml ", "test.yml", "test.yml"]
    )

    #expect(result.workflows == ["test.yml"])
    #expect(await capture.request?.workflows == ["test.yml"])
  }

  @Test(
    "Rejects invalid or finished selections before authentication",
    arguments: [
      CancelSelection(
        workflows: [""],
        pipeline: cancelPipeline([cancelWorkflow("test.yml", .running)])
      ),
      CancelSelection(
        workflows: ["missing.yml"],
        pipeline: cancelPipeline([cancelWorkflow("test.yml", .running)])
      ),
      CancelSelection(
        workflows: [],
        pipeline: cancelPipeline([cancelWorkflow("test.yml", .success)])
      ),
      CancelSelection(
        workflows: ["test.yml"],
        pipeline: cancelPipeline([cancelWorkflow("test.yml", .cancelled)])
      ),
      CancelSelection(
        workflows: [],
        pipeline: cancelPipeline([])
      ),
    ]
  )
  func rejectsInvalidOrFinishedSelections(selection: CancelSelection) async {
    let capture = CancelCapture()
    let service = makeCancelService(pipeline: selection.pipeline, capture: capture)

    await #expect(throws: TangledError.self) {
      _ = try await service.cancel(
        pipelineID: cancelPipelineID,
        repositoryDID: "did:plc:repository",
        workflows: selection.workflows
      )
    }
    #expect(await capture.auth == nil)
    #expect(await capture.request == nil)
  }
}

private let cancelPipelineID = "3mrlprkttms22"

struct CancelSelection: CustomTestStringConvertible, Sendable {
  let workflows: [String]
  let pipeline: Pipeline

  var testDescription: String {
    "\(workflows)|\(pipeline.workflows.map { "\($0.name):\($0.status.rawValue)" })"
  }
}

private func cancelPipeline(_ workflows: [PipelineWorkflow]) -> Pipeline {
  Pipeline(
    id: cancelPipelineID,
    repositoryDID: "did:plc:repository",
    commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    trigger: .manual(
      PipelineManualTrigger(sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    ),
    workflows: workflows
  )
}

private func cancelWorkflow(
  _ name: String,
  _ status: PipelineWorkflowStatus
) -> PipelineWorkflow {
  PipelineWorkflow(id: name, name: name, status: status)
}

private func makeCancelService(
  pipeline: Pipeline,
  capture: CancelCapture
) -> PipelineCancelService {
  PipelineCancelService(
    dependencies: PipelineCancelDependencies(
      pipeline: { _ in pipeline },
      serviceAuthToken: { audience, lxm in
        await capture.recordAuth(audience: audience, lxm: lxm)
        return "service-token"
      },
      cancel: { repositoryDID, pipelineID, workflows, token in
        await capture.recordRequest(
          repositoryDID: repositoryDID,
          pipelineID: pipelineID,
          workflows: workflows,
          token: token
        )
      },
      serviceAudience: { "did:web:spindle.example" }
    )
  )
}

private actor CancelCapture {
  struct Auth: Equatable {
    let audience: String
    let lxm: String
  }

  struct Request: Equatable {
    let repositoryDID: String
    let pipelineID: String
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
    pipelineID: String,
    workflows: [String],
    token: String
  ) {
    request = Request(
      repositoryDID: repositoryDID,
      pipelineID: pipelineID,
      workflows: workflows,
      token: token
    )
  }
}
