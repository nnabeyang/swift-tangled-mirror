import Testing

@testable import SwiftTangled

@Suite struct PipelineRunServiceTests {
  @Test func runsAllWorkflowsAtExplicitCommit() async throws {
    let capture = RunCapture()
    let service = makeRunService(capture: capture)

    let result = try await service.run(
      repositoryDID: "did:plc:repository",
      commit: runCommit
    )

    #expect(
      result == "at://did:plc:spindle/sh.tangled.ci.pipeline/3mrunpipeline"
    )
    #expect(
      await capture.auth
        == .init(
          audience: "did:web:spindle.example",
          lxm: "sh.tangled.ci.triggerPipeline"
        )
    )
    let request = try #require(await capture.request)
    #expect(request.repositoryDID == "did:plc:repository")
    #expect(request.trigger == .manual(PipelineManualTrigger(sha: runCommit)))
    #expect(request.workflows == nil)
    #expect(request.token == "service-token")
  }

  @Test func normalizesRefWorkflowsAndInputs() async throws {
    let capture = RunCapture()
    let service = makeRunService(capture: capture)

    _ = try await service.run(
      repositoryDID: "did:plc:repository",
      commit: runCommit,
      ref: " refs/heads/main ",
      workflows: [" verify.yml ", "deploy.yml", "verify.yml"],
      inputs: [
        PipelineManualInput(key: " configuration ", value: "release"),
        PipelineManualInput(key: "empty", value: ""),
      ]
    )

    let request = try #require(await capture.request)
    #expect(request.workflows == ["verify.yml", "deploy.yml"])
    #expect(
      request.trigger
        == .manual(
          PipelineManualTrigger(
            sha: runCommit,
            ref: "refs/heads/main",
            inputs: [
              PipelineManualInput(key: "configuration", value: "release"),
              PipelineManualInput(key: "empty", value: ""),
            ]
          )
        )
    )
  }

  @Test(
    "Rejects invalid values before authentication",
    arguments: [
      RunInvalidRequest(
        commit: "short",
        ref: nil,
        workflows: [],
        inputs: []
      ),
      RunInvalidRequest(
        commit: "gggggggggggggggggggggggggggggggggggggggg",
        ref: nil,
        workflows: [],
        inputs: []
      ),
      RunInvalidRequest(
        commit: runCommit,
        ref: " ",
        workflows: [],
        inputs: []
      ),
      RunInvalidRequest(
        commit: runCommit,
        ref: nil,
        workflows: [""],
        inputs: []
      ),
      RunInvalidRequest(
        commit: runCommit,
        ref: nil,
        workflows: [],
        inputs: [PipelineManualInput(key: " ", value: "value")]
      ),
      RunInvalidRequest(
        commit: runCommit,
        ref: nil,
        workflows: [],
        inputs: [
          PipelineManualInput(key: "mode", value: "debug"),
          PipelineManualInput(key: "MODE", value: "release"),
        ]
      ),
    ]
  )
  func rejectsInvalidValuesBeforeAuthentication(request: RunInvalidRequest) async {
    let capture = RunCapture()
    let service = makeRunService(capture: capture)

    await #expect(throws: TangledError.self) {
      _ = try await service.run(
        repositoryDID: "did:plc:repository",
        commit: request.commit,
        ref: request.ref,
        workflows: request.workflows,
        inputs: request.inputs
      )
    }
    #expect(await capture.auth == nil)
    #expect(await capture.request == nil)
  }
}

private let runCommit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

struct RunInvalidRequest: CustomTestStringConvertible, Sendable {
  let commit: String
  let ref: String?
  let workflows: [String]
  let inputs: [PipelineManualInput]

  var testDescription: String {
    "\(commit)|\(ref ?? "nil")|\(workflows)|\(inputs)"
  }
}

private func makeRunService(capture: RunCapture) -> PipelineRunService {
  PipelineRunService(
    dependencies: PipelineRunDependencies(
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
        return "at://did:plc:spindle/sh.tangled.ci.pipeline/3mrunpipeline"
      },
      serviceAudience: { "did:web:spindle.example" }
    )
  )
}

private actor RunCapture {
  struct Auth: Equatable {
    let audience: String
    let lxm: String
  }

  struct Request: Equatable {
    let repositoryDID: String
    let trigger: PipelineTrigger
    let workflows: [String]?
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
    workflows: [String]?,
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
