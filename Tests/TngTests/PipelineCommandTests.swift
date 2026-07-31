import Foundation
import SwiftAtproto
import SwiftTangled
import Testing

@testable import tng

@Suite struct PipelineCommandTests {
  @Test func parsesPipelineArguments() throws {
    let list = try PipelineListCommand.parse([
      "alice.example/core", "--spindle", "spindle.example", "--limit", "25",
      "--cursor", "next", "--json",
    ])
    #expect(list.repository == "alice.example/core")
    #expect(list.spindle == "spindle.example")
    #expect(list.limit == 25)
    #expect(list.cursor == "next")
    #expect(list.json)

    let view = try PipelineViewCommand.parse([
      samplePipelineID, "--repo", "alice.example/core", "--spindle", "spindle.example",
      "--json",
    ])
    #expect(view.pipelineID == samplePipelineID)
    #expect(view.repository == "alice.example/core")
    #expect(view.spindle == "spindle.example")
    #expect(view.json)

    let status = try PipelineStatusCommand.parse([
      samplePipelineID, "--repo", "alice.example/core", "--spindle", "spindle.example",
      "--json",
    ])
    #expect(status.pipelineID == samplePipelineID)
    #expect(status.repository == "alice.example/core")
    #expect(status.spindle == "spindle.example")
    #expect(status.json)

    let watch = try PipelineWatchCommand.parse([
      samplePipelineID, "--repo", "alice.example/core", "--spindle", "spindle.example",
      "--interval", "0.5", "--json",
    ])
    #expect(watch.pipelineID == samplePipelineID)
    #expect(watch.repository == "alice.example/core")
    #expect(watch.spindle == "spindle.example")
    #expect(watch.interval == 0.5)
    #expect(watch.json)

    let logs = try PipelineLogsCommand.parse([
      samplePipelineID, "--repo", "alice.example/core", "--spindle", "spindle.example",
      "--workflow", "verify.yml", "--workflow", "deploy.yml", "--json",
    ])
    #expect(logs.pipelineID == samplePipelineID)
    #expect(logs.repository == "alice.example/core")
    #expect(logs.spindle == "spindle.example")
    #expect(logs.workflow == ["verify.yml", "deploy.yml"])
    #expect(logs.json)

    let retry = try PipelineRetryCommand.parse([
      samplePipelineID, "--repo", "alice.example/core", "--spindle", "spindle.example",
      "--workflow", "verify.yml", "--json",
    ])
    #expect(retry.pipelineID == samplePipelineID)
    #expect(retry.repository == "alice.example/core")
    #expect(retry.spindle == "spindle.example")
    #expect(retry.workflow == "verify.yml")
    #expect(retry.json)

    let run = try PipelineRunCommand.parse([
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "--repo", "alice.example/core",
      "--spindle", "spindle.example",
      "--ref", "refs/heads/main",
      "--workflow", "verify.yml",
      "--workflow", "deploy.yml",
      "--input", "configuration=release",
      "--input", "expression=one=two",
      "--json",
    ])
    #expect(run.commit == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(run.repository == "alice.example/core")
    #expect(run.spindle == "spindle.example")
    #expect(run.ref == "refs/heads/main")
    #expect(run.workflow == ["verify.yml", "deploy.yml"])
    #expect(
      run.input == [
        PipelineRunInput(key: "configuration", value: "release"),
        PipelineRunInput(key: "expression", value: "one=two"),
      ]
    )
    #expect(run.json)

    let cancel = try PipelineCancelCommand.parse([
      samplePipelineID,
      "--repo", "alice.example/core",
      "--spindle", "spindle.example",
      "--workflow", "verify.yml",
      "--workflow", "deploy.yml",
      "--json",
    ])
    #expect(cancel.pipelineID == samplePipelineID)
    #expect(cancel.repository == "alice.example/core")
    #expect(cancel.spindle == "spindle.example")
    #expect(cancel.workflow == ["verify.yml", "deploy.yml"])
    #expect(cancel.json)

    #expect(throws: (any Error).self) {
      _ = try PipelineListCommand.parse(["--limit", "0"])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineListCommand.parse(["--limit", "251"])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineListCommand.parse(["--spindle", ""])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineViewCommand.parse([samplePipelineID, "--spindle", ""])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineStatusCommand.parse([samplePipelineID, "--spindle", ""])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineWatchCommand.parse([samplePipelineID, "--interval", "0.1"])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineWatchCommand.parse([samplePipelineID, "--interval", "61"])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineWatchCommand.parse([samplePipelineID, "--spindle", ""])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineLogsCommand.parse([samplePipelineID, "--spindle", ""])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineLogsCommand.parse([samplePipelineID, "--workflow", ""])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineRetryCommand.parse([samplePipelineID, "--workflow", ""])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineRunCommand.parse([
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--ref", "",
      ])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineRunCommand.parse([
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--workflow", "",
      ])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineRunCommand.parse([
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--input", "missing-separator",
      ])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineRunCommand.parse([
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--input", "=missing-key",
      ])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineCancelCommand.parse([samplePipelineID, "--spindle", ""])
    }
    #expect(throws: (any Error).self) {
      _ = try PipelineCancelCommand.parse([samplePipelineID, "--workflow", ""])
    }
  }

  @Test func listUsesCurrentRepositorySpindleAndFormatsPage() async throws {
    let recorder = PipelineCommandRecorder()
    let service = PipelineCommandService(
      dependencies: dependencies(
        recorder: recorder,
        repositoryRecord: sampleRepositoryRecord(spindle: "fresh.spindle.example")
      )
    )

    let output = try await service.list(
      repository: "alice.example/core",
      spindle: nil,
      limit: 25,
      cursor: "previous",
      json: false
    )

    #expect(output.stdout.hasPrefix("ID\tCOMMIT\tTRIGGER\tWORKFLOWS\tCREATED\n"))
    #expect(output.stdout.contains("3mr7m2f6ger22\taaaaaaaaaaaa\tpush:refs/heads/main"))
    #expect(output.stdout.contains("build.yml:success, test.yml:failed"))
    #expect(output.stderr == "Next cursor: next-page\n")
    #expect(await recorder.references() == ["alice.example/core"])
    #expect(
      await recorder.listCalls()
        == [
          .init(
            spindle: "fresh.spindle.example",
            repositoryDID: "did:plc:repository",
            cursor: "previous",
            limit: 25
          )
        ]
    )
  }

  @Test func listUsesOriginFallbackAndPreservesPageJSON() async throws {
    let recorder = PipelineCommandRecorder()
    let service = PipelineCommandService(
      dependencies: dependencies(
        recorder: recorder,
        originURL: { "git@tangled.org:alice.example/core.git" }
      )
    )

    let output = try await service.list(
      repository: nil,
      spindle: nil,
      limit: 30,
      cursor: nil,
      json: true
    )

    let page = try JSONDecoder().decode(PipelinePage.self, from: Data(output.stdout.utf8))
    #expect(page.cursor == "next-page")
    #expect(page.total == 42)
    #expect(page.pipelines.first?.id == samplePipelineID)
    #expect(output.stderr.isEmpty)
    #expect(await recorder.references() == ["git@tangled.org:alice.example/core.git"])
  }

  @Test func viewAndStatusFormatHumanAndJSONOutput() async throws {
    let recorder = PipelineCommandRecorder()
    let service = PipelineCommandService(dependencies: dependencies(recorder: recorder))

    let view = try await service.view(
      pipelineID: samplePipelineID,
      repository: "alice.example/core",
      spindle: nil,
      json: false
    )
    let viewJSON = try await service.view(
      pipelineID: samplePipelineID,
      repository: "alice.example/core",
      spindle: nil,
      json: true
    )
    let status = try await service.status(
      pipelineID: samplePipelineID,
      repository: "alice.example/core",
      spindle: nil,
      json: false
    )
    let statusJSON = try await service.status(
      pipelineID: samplePipelineID,
      repository: "alice.example/core",
      spindle: nil,
      json: true
    )

    #expect(view.stdout.contains("ID\t3mr7m2f6ger22"))
    #expect(view.stdout.contains("Trigger ref\trefs/heads/main"))
    #expect(view.stdout.contains("Workflow 1 status\tsuccess"))
    #expect(view.stdout.contains("Workflow 2 error\tUser step error: exited with code 1"))
    let pipeline = try JSONDecoder().decode(Pipeline.self, from: Data(viewJSON.stdout.utf8))
    #expect(pipeline.id == samplePipelineID)

    #expect(status.stdout.hasPrefix("WORKFLOW\tSTATUS\tSTARTED\tFINISHED\tERROR\n"))
    #expect(status.stdout.contains("test.yml\tfailed"))
    let workflows = try JSONDecoder().decode(
      [PipelineWorkflow].self,
      from: Data(statusJSON.stdout.utf8)
    )
    #expect(workflows.map(\.status) == [.success, .failed])
    #expect(
      await recorder.pipelineCalls()
        == Array(
          repeating: .init(spindle: "spindle.tangled.sh", pipelineID: samplePipelineID),
          count: 4
        )
    )
  }

  @Test func retryFormatsDerivedIDAndXRPCShapedJSON() async throws {
    let repository = sampleRepositoryRecord()
    let pipelineURI =
      "at://did:web:knot1.tangled.sh/sh.tangled.pipeline/3mrruwyseci22"
    let service = PipelineCommandService(
      dependencies: PipelineCommandDependencies(
        resolveRepository: { _ in repository },
        pipelines: { _, _, _, _ in PipelinePage(pipelines: [], total: 0) },
        pipeline: { _, _ in samplePipeline() },
        retry: { spindle, repositoryDID, pipelineID, workflow in
          #expect(spindle == "spindle.tangled.sh")
          #expect(repositoryDID == "did:plc:repository")
          #expect(pipelineID == samplePipelineID)
          #expect(workflow == "verify.yml")
          return pipelineURI
        },
        originURL: { "unused" },
        sleep: { _ in }
      )
    )

    let human = try await service.retry(
      pipelineID: samplePipelineID,
      repository: "alice.example/core",
      spindle: nil,
      workflow: "verify.yml",
      json: false
    )
    let json = try await service.retry(
      pipelineID: samplePipelineID,
      repository: "alice.example/core",
      spindle: nil,
      workflow: "verify.yml",
      json: true
    )

    #expect(human.stdout.contains("Pipeline ID\t3mrruwyseci22"))
    #expect(human.stdout.contains("Pipeline URI\t\(pipelineURI)"))
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: String]
    )
    #expect(object == ["pipeline": pipelineURI])
  }

  @Test func runResolvesRepositoryAndFormatsDerivedID() async throws {
    let repository = sampleRepositoryRecord()
    let pipelineURI =
      "at://did:web:knot1.tangled.sh/sh.tangled.ci.pipeline/3mrrunpipeline"
    let service = PipelineCommandService(
      dependencies: PipelineCommandDependencies(
        resolveRepository: { reference in
          #expect(reference == "alice.example/core")
          return repository
        },
        pipelines: { _, _, _, _ in PipelinePage(pipelines: [], total: 0) },
        pipeline: { _, _ in samplePipeline() },
        run: { spindle, repositoryDID, commit, ref, workflows, inputs in
          #expect(spindle == "https://explicit.spindle.example")
          #expect(repositoryDID == "did:plc:repository")
          #expect(commit == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
          #expect(ref == "refs/heads/main")
          #expect(workflows == ["verify.yml", "deploy.yml"])
          #expect(
            inputs == [
              PipelineManualInput(key: "configuration", value: "release")
            ]
          )
          return pipelineURI
        },
        originURL: { "unused" },
        sleep: { _ in }
      )
    )

    let human = try await service.run(
      commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      repository: "alice.example/core",
      spindle: "explicit.spindle.example",
      ref: "refs/heads/main",
      workflows: ["verify.yml", "deploy.yml"],
      inputs: [PipelineManualInput(key: "configuration", value: "release")],
      json: false
    )
    let json = try await service.run(
      commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      repository: "alice.example/core",
      spindle: "explicit.spindle.example",
      ref: "refs/heads/main",
      workflows: ["verify.yml", "deploy.yml"],
      inputs: [PipelineManualInput(key: "configuration", value: "release")],
      json: true
    )

    #expect(human.stdout.contains("Pipeline ID\t3mrrunpipeline"))
    #expect(human.stdout.contains("Pipeline URI\t\(pipelineURI)"))
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: String]
    )
    #expect(object == ["pipeline": pipelineURI])
  }

  @Test func cancelResolvesRepositoryAndFormatsSelectedWorkflows() async throws {
    let repository = sampleRepositoryRecord()
    let service = PipelineCommandService(
      dependencies: PipelineCommandDependencies(
        resolveRepository: { reference in
          #expect(reference == "alice.example/core")
          return repository
        },
        pipelines: { _, _, _, _ in PipelinePage(pipelines: [], total: 0) },
        pipeline: { _, _ in samplePipeline() },
        cancel: { spindle, repositoryDID, pipelineID, workflows in
          #expect(spindle == "https://explicit.spindle.example")
          #expect(repositoryDID == "did:plc:repository")
          #expect(pipelineID == samplePipelineID)
          #expect(workflows == ["build.yml", "test.yml"])
          return PipelineCancellation(
            pipeline: pipelineID,
            workflows: ["test.yml"]
          )
        },
        originURL: { "unused" },
        sleep: { _ in }
      )
    )

    let human = try await service.cancel(
      pipelineID: samplePipelineID,
      repository: "alice.example/core",
      spindle: "explicit.spindle.example",
      workflows: ["build.yml", "test.yml"],
      json: false
    )
    let json = try await service.cancel(
      pipelineID: samplePipelineID,
      repository: "alice.example/core",
      spindle: "explicit.spindle.example",
      workflows: ["build.yml", "test.yml"],
      json: true
    )

    #expect(human.stdout.contains("Pipeline ID\t\(samplePipelineID)"))
    #expect(human.stdout.contains("Cancellation requested\ttest.yml"))
    let cancellation = try JSONDecoder().decode(
      PipelineCancellation.self,
      from: Data(json.stdout.utf8)
    )
    #expect(
      cancellation
        == PipelineCancellation(pipeline: samplePipelineID, workflows: ["test.yml"])
    )
  }

  @Test func listRejectsMissingDIDAndReadsRejectMissingSpindle() async {
    let recorder = PipelineCommandRecorder()
    let missingDID = PipelineCommandService(
      dependencies: dependencies(
        recorder: recorder,
        repositoryRecord: sampleRepositoryRecord(repositoryDID: nil)
      )
    )
    let missingSpindle = PipelineCommandService(
      dependencies: dependencies(
        recorder: recorder,
        repositoryRecord: sampleRepositoryRecord(spindle: nil)
      )
    )

    await #expect(throws: TangledError.self) {
      _ = try await missingDID.list(
        repository: "alice.example/core",
        spindle: "explicit.spindle.example",
        limit: 30,
        cursor: nil,
        json: false
      )
    }
    await #expect(throws: TangledError.self) {
      _ = try await missingSpindle.view(
        pipelineID: samplePipelineID,
        repository: "alice.example/core",
        spindle: nil,
        json: false
      )
    }
    #expect(await recorder.listCalls().isEmpty)
    #expect(await recorder.pipelineCalls().isEmpty)
  }

  @Test func explicitSpindleOverridesRepositoryAndSkipsUnneededDiscovery() async throws {
    let listRecorder = PipelineCommandRecorder()
    let listService = PipelineCommandService(
      dependencies: dependencies(
        recorder: listRecorder,
        repositoryRecord: sampleRepositoryRecord(spindle: nil)
      )
    )

    _ = try await listService.list(
      repository: "alice.example/core",
      spindle: "explicit.spindle.example",
      limit: 30,
      cursor: nil,
      json: false
    )

    #expect(await listRecorder.references() == ["alice.example/core"])
    #expect(
      await listRecorder.listCalls()
        == [
          .init(
            spindle: "https://explicit.spindle.example",
            repositoryDID: "did:plc:repository",
            cursor: nil,
            limit: 30
          )
        ]
    )

    let readRecorder = PipelineCommandRecorder()
    let pipeline = samplePipeline()
    let readService = PipelineCommandService(
      dependencies: PipelineCommandDependencies(
        resolveRepository: { _ in
          throw TangledError.invalidRequest("repository discovery must be skipped")
        },
        pipelines: { _, _, _, _ in PipelinePage(pipelines: [], total: 0) },
        pipeline: { spindle, pipelineID in
          await readRecorder.record(
            pipeline: .init(spindle: spindle, pipelineID: pipelineID)
          )
          return pipeline
        },
        originURL: {
          throw TangledError.invalidRequest("origin must be skipped")
        },
        sleep: { _ in }
      )
    )

    _ = try await readService.view(
      pipelineID: samplePipelineID,
      repository: nil,
      spindle: "explicit.spindle.example",
      json: false
    )
    _ = try await readService.status(
      pipelineID: samplePipelineID,
      repository: nil,
      spindle: "explicit.spindle.example",
      json: false
    )

    #expect(
      await readRecorder.pipelineCalls()
        == Array(
          repeating: .init(
            spindle: "https://explicit.spindle.example",
            pipelineID: samplePipelineID
          ),
          count: 2
        )
    )
  }

  @Test func invalidExplicitSpindleFailsBeforeDiscoveryOrRequest() async {
    let recorder = PipelineCommandRecorder()
    let service = PipelineCommandService(dependencies: dependencies(recorder: recorder))

    await #expect(throws: TangledError.self) {
      _ = try await service.list(
        repository: "alice.example/core",
        spindle: "ftp://spindle.example",
        limit: 30,
        cursor: nil,
        json: false
      )
    }
    await #expect(throws: TangledError.self) {
      _ = try await service.view(
        pipelineID: samplePipelineID,
        repository: "alice.example/core",
        spindle: "ftp://spindle.example",
        json: false
      )
    }

    #expect(await recorder.references().isEmpty)
    #expect(await recorder.listCalls().isEmpty)
    #expect(await recorder.pipelineCalls().isEmpty)
  }

  @Test func pipelineReadsDoNotRequireRepositoryDID() async throws {
    let recorder = PipelineCommandRecorder()
    let service = PipelineCommandService(
      dependencies: dependencies(
        recorder: recorder,
        repositoryRecord: sampleRepositoryRecord(repositoryDID: nil)
      )
    )

    _ = try await service.view(
      pipelineID: samplePipelineID,
      repository: "alice.example/core",
      spindle: nil,
      json: false
    )
    _ = try await service.status(
      pipelineID: samplePipelineID,
      repository: "alice.example/core",
      spindle: nil,
      json: false
    )

    #expect(
      await recorder.pipelineCalls()
        == Array(
          repeating: .init(spindle: "spindle.tangled.sh", pipelineID: samplePipelineID),
          count: 2
        )
    )
  }

  @Test func watchPrintsOnlyStateChangesAndFinishesOnSuccess() async throws {
    let sequence = PipelineSequence([
      watchPipeline(.pending),
      watchPipeline(.running),
      watchPipeline(.running),
      watchPipeline(.success),
    ])
    let output = PipelineStreamRecorder()
    let service = PipelineCommandService(
      dependencies: watchDependencies(sequence: sequence),
      streamWriter: output.writer
    )

    try await service.watch(
      pipelineID: samplePipelineID,
      repository: "alice.example/core",
      spindle: nil,
      interval: 0.5,
      json: false
    )

    #expect(output.stdout.components(separatedBy: "Pipeline \(samplePipelineID)\n").count == 4)
    #expect(output.stdout.contains("verify.yml\tpending"))
    #expect(output.stdout.contains("verify.yml\trunning"))
    #expect(output.stdout.contains("verify.yml\tsuccess"))
    #expect(await sequence.requestCount() == 4)
    #expect(await sequence.delays() == [0.5, 0.5, 0.5])
  }

  @Test func watchStreamsPipelineStateAsNDJSON() async throws {
    let sequence = PipelineSequence([
      watchPipeline(.running),
      watchPipeline(.success),
    ])
    let output = PipelineStreamRecorder()
    let service = PipelineCommandService(
      dependencies: watchDependencies(sequence: sequence),
      streamWriter: output.writer
    )

    try await service.watch(
      pipelineID: samplePipelineID,
      repository: nil,
      spindle: nil,
      interval: 2,
      json: true
    )

    let values = try output.stdout.split(separator: "\n").map {
      try JSONDecoder().decode(Pipeline.self, from: Data($0.utf8))
    }
    #expect(values.map { $0.workflows[0].status } == [.running, .success])
    #expect(output.stderr.isEmpty)
  }

  @Test func logsPreservesDataStreamsAndPrintsControlMetadata() async throws {
    let output = PipelineStreamRecorder()
    let repository = sampleRepositoryRecord()
    let service = PipelineCommandService(
      dependencies: PipelineCommandDependencies(
        resolveRepository: { _ in repository },
        pipelines: { _, _, _, _ in PipelinePage(pipelines: [], total: 0) },
        pipeline: { _, _ in throw TangledError.invalidRequest("unused") },
        pipelineLogs: { spindle, pipelineID, workflows in
          #expect(spindle == "spindle.tangled.sh")
          #expect(pipelineID == samplePipelineID)
          #expect(workflows == ["verify.yml"])
          return pipelineLogStream()
        },
        originURL: { "git@tangled.org:alice.example/core.git" },
        sleep: { _ in }
      ),
      streamWriter: output.writer
    )

    try await service.logs(
      pipelineID: samplePipelineID,
      repository: "alice.example/core",
      spindle: nil,
      workflows: ["verify.yml"],
      json: false
    )

    #expect(output.stdout == "hello\n")
    #expect(
      output.stderr
        == "[verify.yml step 2 user start] Run tests — swift test\nwarning\n"
    )
  }

  @Test func logsStreamsEveryEventAsNDJSONOnStandardOutput() async throws {
    let output = PipelineStreamRecorder()
    let service = PipelineCommandService(
      dependencies: PipelineCommandDependencies(
        resolveRepository: { _ in
          throw TangledError.invalidRequest("repository discovery must be skipped")
        },
        pipelines: { _, _, _, _ in PipelinePage(pipelines: [], total: 0) },
        pipeline: { _, _ in throw TangledError.invalidRequest("unused") },
        pipelineLogs: { spindle, _, workflows in
          #expect(spindle == "https://spindle.example")
          #expect(workflows.isEmpty)
          return pipelineLogStream()
        },
        originURL: {
          throw TangledError.invalidRequest("origin must be skipped")
        },
        sleep: { _ in }
      ),
      streamWriter: output.writer
    )

    try await service.logs(
      pipelineID: samplePipelineID,
      repository: nil,
      spindle: "spindle.example",
      workflows: [],
      json: true
    )

    let events = try output.stdout.split(separator: "\n").map {
      try JSONDecoder().decode(PipelineLogEvent.self, from: Data($0.utf8))
    }
    #expect(events == pipelineLogEvents())
    #expect(output.stderr.isEmpty)
  }

  @Test func explicitSpindleSkipsRepositoryDiscovery() async throws {
    let sequence = PipelineSequence([watchPipeline(.success)])
    let output = PipelineStreamRecorder()
    let service = PipelineCommandService(
      dependencies: PipelineCommandDependencies(
        resolveRepository: { _ in
          throw TangledError.invalidRequest("repository discovery must be skipped")
        },
        pipelines: { _, _, _, _ in PipelinePage(pipelines: [], total: 0) },
        pipeline: { spindle, _ in
          #expect(spindle == "https://spindle.example")
          return try await sequence.next()
        },
        originURL: {
          throw TangledError.invalidRequest("origin must be skipped")
        },
        sleep: { _ in }
      ),
      streamWriter: output.writer
    )

    try await service.watch(
      pipelineID: samplePipelineID,
      repository: nil,
      spindle: "spindle.example",
      interval: 2,
      json: false
    )
    #expect(output.stdout.contains("verify.yml\tsuccess"))
  }

  @Test func watchFailsForEveryUnsuccessfulTerminalState() async {
    for status in [
      PipelineWorkflowStatus.failed,
      .timeout,
      .cancelled,
    ] {
      let sequence = PipelineSequence([watchPipeline(status)])
      let service = PipelineCommandService(
        dependencies: watchDependencies(sequence: sequence),
        streamWriter: PipelineStreamRecorder().writer
      )

      await #expect(throws: PipelineWatchFailure.self) {
        try await service.watch(
          pipelineID: samplePipelineID,
          repository: "alice.example/core",
          spindle: nil,
          interval: 2,
          json: false
        )
      }
      #expect(await sequence.delays().isEmpty)
    }
  }
}

extension PipelineCommandTests {
  fileprivate func dependencies(
    recorder: PipelineCommandRecorder,
    repositoryRecord: TangledRecord<Repository>? = nil,
    pipeline: Pipeline? = nil,
    originURL: @escaping @Sendable () throws -> String = { "unused" }
  ) -> PipelineCommandDependencies {
    let repositoryRecord = repositoryRecord ?? sampleRepositoryRecord()
    let pipeline = pipeline ?? samplePipeline()
    return PipelineCommandDependencies(
      resolveRepository: { reference in
        await recorder.record(reference: reference)
        return repositoryRecord
      },
      pipelines: { spindle, repositoryDID, cursor, limit in
        await recorder.record(
          list: .init(
            spindle: spindle,
            repositoryDID: repositoryDID,
            cursor: cursor,
            limit: limit
          )
        )
        return PipelinePage(pipelines: [pipeline], cursor: "next-page", total: 42)
      },
      pipeline: { spindle, pipelineID in
        await recorder.record(
          pipeline: .init(spindle: spindle, pipelineID: pipelineID)
        )
        return pipeline
      },
      originURL: originURL,
      sleep: { _ in }
    )
  }

  fileprivate func watchDependencies(
    sequence: PipelineSequence
  ) -> PipelineCommandDependencies {
    let repository = sampleRepositoryRecord()
    return PipelineCommandDependencies(
      resolveRepository: { _ in repository },
      pipelines: { _, _, _, _ in PipelinePage(pipelines: [], total: 0) },
      pipeline: { _, _ in try await sequence.next() },
      originURL: { "git@tangled.org:alice.example/core.git" },
      sleep: { interval in await sequence.record(delay: interval) }
    )
  }

  fileprivate func watchPipeline(_ status: PipelineWorkflowStatus) -> Pipeline {
    Pipeline(
      id: samplePipelineID,
      repositoryDID: "did:plc:repository",
      commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      trigger: .push(
        PipelinePushTrigger(
          ref: "refs/heads/main",
          newSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          oldSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )
      ),
      workflows: [
        PipelineWorkflow(
          id: "verify.yml",
          name: "verify.yml",
          status: status
        )
      ]
    )
  }

  fileprivate func pipelineLogStream() -> PipelineLogEventStream {
    let events = pipelineLogEvents()
    return AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }

  fileprivate func pipelineLogEvents() -> [PipelineLogEvent] {
    let time = FormatString<Date>(rawValue: "2026-07-30T12:00:00Z")
    return [
      .control(
        PipelineLogControl(
          time: time,
          workflow: "verify.yml",
          step: 2,
          content: "Run tests",
          command: "swift test",
          status: .start,
          kind: .user
        )
      ),
      .data(
        PipelineLogData(
          time: time,
          workflow: "verify.yml",
          step: 2,
          content: "hello\n",
          stream: .stdout
        )
      ),
      .data(
        PipelineLogData(
          time: time,
          workflow: "verify.yml",
          step: 2,
          content: "warning\n",
          stream: .stderr
        )
      ),
    ]
  }

  fileprivate func sampleRepositoryRecord(
    repositoryDID: String? = "did:plc:repository",
    spindle: String? = "spindle.tangled.sh"
  ) -> TangledRecord<Repository> {
    TangledRecord(
      uri: "at://did:plc:owner/sh.tangled.repo/core",
      value: Repository(
        name: "core",
        knot: "knot1.tangled.sh",
        spindle: spindle,
        repoDID: repositoryDID,
        createdAt: FormatString<Date>(rawValue: "2026-07-20T17:44:38Z")
      )
    )
  }

  fileprivate func samplePipeline() -> Pipeline {
    Pipeline(
      id: samplePipelineID,
      repositoryDID: "did:plc:repository",
      commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      createdAt: FormatString<Date>(rawValue: "2026-07-22T08:35:09+03:00"),
      trigger: .push(
        PipelinePushTrigger(
          ref: "refs/heads/main",
          newSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          oldSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )
      ),
      workflows: [
        PipelineWorkflow(
          id: "build.yml",
          name: "build.yml",
          status: .success,
          startedAt: FormatString<Date>(rawValue: "2026-07-22T08:35:10+03:00"),
          finishedAt: FormatString<Date>(rawValue: "2026-07-22T08:36:10+03:00")
        ),
        PipelineWorkflow(
          id: "test.yml",
          name: "test.yml",
          status: .failed,
          error: "User step error: exited with code 1"
        ),
      ]
    )
  }
}

private let samplePipelineID = "3mr7m2f6ger22"

private actor PipelineCommandRecorder {
  struct ListCall: Equatable, Sendable {
    let spindle: String
    let repositoryDID: String
    let cursor: String?
    let limit: Int
  }

  struct PipelineCall: Equatable, Sendable {
    let spindle: String
    let pipelineID: String
  }

  private var recordedReferences: [String] = []
  private var recordedListCalls: [ListCall] = []
  private var recordedPipelineCalls: [PipelineCall] = []

  func record(reference: String) {
    recordedReferences.append(reference)
  }

  func record(list: ListCall) {
    recordedListCalls.append(list)
  }

  func record(pipeline: PipelineCall) {
    recordedPipelineCalls.append(pipeline)
  }

  func references() -> [String] {
    recordedReferences
  }

  func listCalls() -> [ListCall] {
    recordedListCalls
  }

  func pipelineCalls() -> [PipelineCall] {
    recordedPipelineCalls
  }
}

private actor PipelineSequence {
  private var values: [Pipeline]
  private var count = 0
  private var recordedDelays: [TimeInterval] = []

  init(_ values: [Pipeline]) {
    self.values = values
  }

  func next() throws -> Pipeline {
    guard !values.isEmpty else {
      throw TangledError.invalidRequest("pipeline test sequence exhausted")
    }
    count += 1
    return values.removeFirst()
  }

  func record(delay: TimeInterval) {
    recordedDelays.append(delay)
  }

  func requestCount() -> Int {
    count
  }

  func delays() -> [TimeInterval] {
    recordedDelays
  }
}

private final class PipelineStreamRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var standardOutput = Data()
  private var standardError = Data()

  var writer: CLIStreamWriter {
    CLIStreamWriter(
      stdout: { [self] data in lock.withLock { standardOutput.append(data) } },
      stderr: { [self] data in lock.withLock { standardError.append(data) } }
    )
  }

  var stdout: String {
    lock.withLock { String(decoding: standardOutput, as: UTF8.self) }
  }

  var stderr: String {
    lock.withLock { String(decoding: standardError, as: UTF8.self) }
  }
}
