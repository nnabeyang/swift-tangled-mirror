import Foundation
import SwiftAtproto
import SwiftTangled

typealias PipelineLogEventStream = AsyncThrowingStream<PipelineLogEvent, any Error>

struct PipelineCommandDependencies: Sendable {
  let resolveRepository: @Sendable (String) async throws -> TangledRecord<Repository>
  let pipelines: @Sendable (String, String, String?, Int) async throws -> PipelinePage
  let pipeline: @Sendable (String, String) async throws -> Pipeline
  let pipelineLogs: @Sendable (String, String, [String]) async throws -> PipelineLogEventStream
  let retry: @Sendable (String, String, String, String?) async throws -> String
  let run:
    @Sendable (
      String, String, String, String?, [String], [PipelineManualInput]
    ) async throws -> String
  let cancel: @Sendable (String, String, String, [String]) async throws -> PipelineCancellation
  let originURL: @Sendable () throws -> String
  let sleep: @Sendable (TimeInterval) async throws -> Void

  init(
    resolveRepository: @escaping @Sendable (String) async throws -> TangledRecord<Repository>,
    pipelines: @escaping @Sendable (String, String, String?, Int) async throws -> PipelinePage,
    pipeline: @escaping @Sendable (String, String) async throws -> Pipeline,
    pipelineLogs:
      @escaping @Sendable (String, String, [String]) async throws ->
      PipelineLogEventStream = { _, _, _ in
        throw TangledError.invalidRequest("pipeline logs are unavailable")
      },
    retry:
      @escaping @Sendable (String, String, String, String?) async throws ->
      String = { _, _, _, _ in
        throw TangledError.invalidRequest("pipeline retry is unavailable")
      },
    run:
      @escaping @Sendable (
        String, String, String, String?, [String], [PipelineManualInput]
      ) async throws -> String = { _, _, _, _, _, _ in
        throw TangledError.invalidRequest("pipeline run is unavailable")
      },
    cancel:
      @escaping @Sendable (String, String, String, [String]) async throws ->
      PipelineCancellation = { _, _, _, _ in
        throw TangledError.invalidRequest("pipeline cancel is unavailable")
      },
    originURL: @escaping @Sendable () throws -> String,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void
  ) {
    self.resolveRepository = resolveRepository
    self.pipelines = pipelines
    self.pipeline = pipeline
    self.pipelineLogs = pipelineLogs
    self.retry = retry
    self.run = run
    self.cancel = cancel
    self.originURL = originURL
    self.sleep = sleep
  }

  static let live: PipelineCommandDependencies = {
    let bobbinClient = BobbinClient()
    let locator = RepositoryLocator(client: bobbinClient)
    return PipelineCommandDependencies(
      resolveRepository: { try await locator.resolve($0) },
      pipelines: { spindle, repositoryDID, cursor, limit in
        try await SpindleClient(spindle: spindle).pipelines(
          repositoryDID: repositoryDID,
          cursor: cursor,
          limit: limit
        )
      },
      pipeline: { spindle, pipelineID in
        try await SpindleClient(spindle: spindle).pipeline(id: pipelineID)
      },
      pipelineLogs: { spindle, pipelineID, workflows in
        try await SpindleClient(spindle: spindle).pipelineLogs(
          pipelineID: pipelineID,
          workflows: workflows
        )
      },
      retry: { spindle, repositoryDID, pipelineID, workflow in
        let pdsClient = try await CLIAuthenticatedClient.make()
        return try await PipelineRetryService(
          spindleClient: SpindleClient(spindle: spindle),
          pdsClient: pdsClient
        ).retry(
          pipelineID: pipelineID,
          repositoryDID: repositoryDID,
          workflow: workflow
        )
      },
      run: { spindle, repositoryDID, commit, ref, workflows, inputs in
        let pdsClient = try await CLIAuthenticatedClient.make()
        return try await PipelineRunService(
          spindleClient: SpindleClient(spindle: spindle),
          pdsClient: pdsClient
        ).run(
          repositoryDID: repositoryDID,
          commit: commit,
          ref: ref,
          workflows: workflows,
          inputs: inputs
        )
      },
      cancel: { spindle, repositoryDID, pipelineID, workflows in
        let pdsClient = try await CLIAuthenticatedClient.make()
        return try await PipelineCancelService(
          spindleClient: SpindleClient(spindle: spindle),
          pdsClient: pdsClient
        ).cancel(
          pipelineID: pipelineID,
          repositoryDID: repositoryDID,
          workflows: workflows
        )
      },
      originURL: { try GitOriginReader().read() },
      sleep: { interval in
        try await Task.sleep(for: .seconds(interval))
      }
    )
  }()
}

struct PipelineCommandService: Sendable {
  private let dependencies: PipelineCommandDependencies
  private let formatter: CLIFormatter
  private let streamWriter: CLIStreamWriter

  init(
    dependencies: PipelineCommandDependencies = .live,
    formatter: CLIFormatter = .plain,
    streamWriter: CLIStreamWriter = .live
  ) {
    self.dependencies = dependencies
    self.formatter = formatter
    self.streamWriter = streamWriter
  }

  func list(
    repository: String?,
    spindle: String?,
    limit: Int,
    cursor: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let explicitSpindle = try normalizedSpindle(spindle)
    let record = try await resolveRepositoryRecord(repository)
    let page = try await dependencies.pipelines(
      try explicitSpindle ?? repositorySpindle(record),
      try repositoryDID(record),
      cursor,
      limit
    )
    return CLICommandOutput(
      stdout: try json ? formatter.json(page) : format(page.pipelines),
      stderr: formatter.cursorDiagnostic(page.cursor, json: json)
    )
  }

  func view(
    pipelineID: String,
    repository: String?,
    spindle: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let resolvedSpindle = try await resolveSpindle(repository: repository, spindle: spindle)
    let pipeline = try await dependencies.pipeline(resolvedSpindle, pipelineID)
    return CLICommandOutput(stdout: try json ? formatter.json(pipeline) : format(pipeline))
  }

  func status(
    pipelineID: String,
    repository: String?,
    spindle: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let resolvedSpindle = try await resolveSpindle(repository: repository, spindle: spindle)
    let pipeline = try await dependencies.pipeline(resolvedSpindle, pipelineID)
    return CLICommandOutput(
      stdout: try json ? formatter.json(pipeline.workflows) : format(pipeline.workflows)
    )
  }

  func watch(
    pipelineID: String,
    repository: String?,
    spindle: String?,
    interval: TimeInterval,
    json: Bool
  ) async throws {
    let resolvedSpindle = try await resolveSpindle(repository: repository, spindle: spindle)
    var previousStates: [PipelineWorkflowState]?

    while !Task.isCancelled {
      let pipeline = try await dependencies.pipeline(resolvedSpindle, pipelineID)
      let states = pipeline.workflows.map(PipelineWorkflowState.init)
      if states != previousStates {
        streamWriter.writeStandardOutput(
          try json ? formatter.jsonLine(pipeline) : formatWatch(pipeline)
        )
        previousStates = states
      }

      if pipeline.isTerminal {
        guard pipeline.isSuccessful else {
          throw PipelineWatchFailure(
            pipelineID: pipeline.id,
            workflows: pipeline.workflows.filter { !$0.status.isSuccessful }
          )
        }
        return
      }
      try await dependencies.sleep(interval)
    }
  }

  func logs(
    pipelineID: String,
    repository: String?,
    spindle: String?,
    workflows: [String],
    json: Bool
  ) async throws {
    let resolvedSpindle = try await resolveSpindle(repository: repository, spindle: spindle)
    let events = try await dependencies.pipelineLogs(
      resolvedSpindle,
      pipelineID,
      workflows
    )
    for try await event in events {
      if json {
        streamWriter.writeStandardOutput(try formatter.jsonLine(event))
        continue
      }
      switch event {
      case .control(let control):
        streamWriter.writeStandardError(format(control))
      case .data(let data):
        if data.stream == .stderr {
          streamWriter.writeStandardError(data.content)
        } else {
          streamWriter.writeStandardOutput(data.content)
        }
      }
    }
  }

  func retry(
    pipelineID: String,
    repository: String?,
    spindle: String?,
    workflow: String?,
    json: Bool
  ) async throws -> CLICommandOutput {
    let explicitSpindle = try normalizedSpindle(spindle)
    let record = try await resolveRepositoryRecord(repository)
    let pipelineURI = try await dependencies.retry(
      try explicitSpindle ?? repositorySpindle(record),
      try repositoryDID(record),
      pipelineID,
      workflow
    )
    return try pipelineTriggerOutput(pipelineURI, json: json)
  }

  func run(
    commit: String,
    repository: String?,
    spindle: String?,
    ref: String?,
    workflows: [String],
    inputs: [PipelineManualInput],
    json: Bool
  ) async throws -> CLICommandOutput {
    let explicitSpindle = try normalizedSpindle(spindle)
    let record = try await resolveRepositoryRecord(repository)
    let pipelineURI = try await dependencies.run(
      try explicitSpindle ?? repositorySpindle(record),
      try repositoryDID(record),
      commit,
      ref,
      workflows,
      inputs
    )
    return try pipelineTriggerOutput(pipelineURI, json: json)
  }

  func cancel(
    pipelineID: String,
    repository: String?,
    spindle: String?,
    workflows: [String],
    json: Bool
  ) async throws -> CLICommandOutput {
    let explicitSpindle = try normalizedSpindle(spindle)
    let record = try await resolveRepositoryRecord(repository)
    let cancellation = try await dependencies.cancel(
      try explicitSpindle ?? repositorySpindle(record),
      try repositoryDID(record),
      pipelineID,
      workflows
    )
    return CLICommandOutput(
      stdout: try json
        ? formatter.json(cancellation)
        : formatter.details([
          ("Pipeline ID", cancellation.pipeline),
          ("Cancellation requested", cancellation.workflows.joined(separator: ", ")),
        ])
    )
  }

  private func pipelineTriggerOutput(
    _ pipelineURI: String,
    json: Bool
  ) throws -> CLICommandOutput {
    try CLICommandOutput(
      stdout: json
        ? formatter.json(PipelineTriggerOutput(pipeline: pipelineURI))
        : formatter.details([
          ("Pipeline ID", try pipelineID(from: pipelineURI)),
          ("Pipeline URI", pipelineURI),
        ])
    )
  }
}

private struct PipelineTriggerOutput: Encodable {
  let pipeline: String
}

extension PipelineCommandService {
  fileprivate func resolveRepositoryRecord(
    _ repository: String?
  ) async throws -> TangledRecord<Repository> {
    let reference = try repository ?? dependencies.originURL()
    return try await dependencies.resolveRepository(reference)
  }

  fileprivate func repositoryDID(_ record: TangledRecord<Repository>) throws -> String {
    guard let repositoryDID = record.value.repoDID, !repositoryDID.isEmpty else {
      throw TangledError.invalidRequest(
        "repository does not expose a repository DID: \(record.uri)"
      )
    }
    return repositoryDID
  }

  fileprivate func repositorySpindle(_ record: TangledRecord<Repository>) throws -> String {
    guard let spindle = record.value.spindle, !spindle.isEmpty else {
      throw TangledError.invalidRequest(
        "repository does not expose a Spindle: \(record.uri)"
      )
    }
    return spindle
  }

  fileprivate func resolveSpindle(
    repository: String?,
    spindle: String?
  ) async throws -> String {
    if let explicitSpindle = try normalizedSpindle(spindle) {
      return explicitSpindle
    }
    return try repositorySpindle(try await resolveRepositoryRecord(repository))
  }

  fileprivate func normalizedSpindle(_ spindle: String?) throws -> String? {
    try spindle.map { try SpindleClient(spindle: $0).baseURL.absoluteString }
  }

  fileprivate func pipelineID(from uri: String) throws -> String {
    guard let id = FormatString<ATURI>(rawValue: uri).typed?.rkey?.rawValue else {
      throw TangledError.decoding(PipelineCommandError.invalidPipelineURI(uri))
    }
    return id
  }

  fileprivate func format(_ pipelines: [Pipeline]) -> String {
    let rows = pipelines.map { pipeline in
      [
        pipeline.id,
        String(pipeline.commit.prefix(12)),
        triggerSummary(pipeline.trigger),
        workflowSummary(pipeline.workflows),
        pipeline.createdAt?.rawValue,
      ]
    }
    return formatter.table(
      headers: ["ID", "COMMIT", "TRIGGER", "WORKFLOWS", "CREATED"],
      rows: rows
    )
  }

  fileprivate func format(_ pipeline: Pipeline) -> String {
    let fields: [(label: String, value: String?)] = [
      ("ID", pipeline.id),
      ("Repository DID", pipeline.repositoryDID),
      ("Source repository DID", pipeline.sourceRepositoryDID),
      ("Commit", pipeline.commit),
      ("Created", pipeline.createdAt?.rawValue),
      ("Trigger", triggerSummary(pipeline.trigger)),
      ("Workflows", String(pipeline.workflows.count)),
    ]
    return formatter.details(
      fields + triggerFields(pipeline.trigger) + workflowFields(pipeline.workflows)
    )
  }

  fileprivate func format(_ workflows: [PipelineWorkflow]) -> String {
    let rows = workflows.map { workflow in
      [
        workflow.name,
        workflow.status.rawValue,
        workflow.startedAt?.rawValue,
        workflow.finishedAt?.rawValue,
        workflow.error,
      ]
    }
    return formatter.table(
      headers: ["WORKFLOW", "STATUS", "STARTED", "FINISHED", "ERROR"],
      rows: rows
    )
  }

  fileprivate func formatWatch(_ pipeline: Pipeline) -> String {
    "Pipeline \(formatter.cell(pipeline.id))\n" + format(pipeline.workflows)
  }

  fileprivate func format(_ control: PipelineLogControl) -> String {
    var metadata = [
      formatter.cell(control.workflow),
      "step \(control.step)",
    ]
    if let kind = control.kind {
      metadata.append(formatter.cell(kind.rawValue))
    }
    if let status = control.status {
      metadata.append(formatter.cell(status.rawValue))
    }
    var result = "[\(metadata.joined(separator: " "))] \(formatter.cell(control.content))"
    if let command = control.command {
      result += " — \(formatter.cell(command))"
    }
    return result + "\n"
  }

  fileprivate func triggerSummary(_ trigger: PipelineTrigger) -> String {
    switch trigger {
    case .push(let value):
      return "push:\(value.ref)"
    case .pullRequest(let value):
      let source = value.sourceBranch ?? String(value.sourceSHA.prefix(12))
      return "pull_request:\(source)->\(value.targetBranch)"
    case .manual(let value):
      return "manual:\(value.ref ?? String(value.sha.prefix(12)))"
    case .unknown(let type, _):
      return type
    }
  }

  fileprivate func workflowSummary(_ workflows: [PipelineWorkflow]) -> String {
    workflows.map { "\($0.name):\($0.status.rawValue)" }.joined(separator: ", ")
  }

  fileprivate func triggerFields(
    _ trigger: PipelineTrigger
  ) -> [(label: String, value: String?)] {
    switch trigger {
    case .push(let value):
      return [
        ("Trigger ref", value.ref),
        ("Trigger new SHA", value.newSHA),
        ("Trigger old SHA", value.oldSHA),
      ]
    case .pullRequest(let value):
      return [
        ("Trigger target branch", value.targetBranch),
        ("Trigger source SHA", value.sourceSHA),
        ("Trigger source repository DID", value.sourceRepositoryDID),
        ("Trigger source branch", value.sourceBranch),
        ("Trigger pull request URI", value.pullRequestURI),
      ]
    case .manual(let value):
      return [
        ("Trigger SHA", value.sha),
        ("Trigger ref", value.ref),
        ("Trigger source repository DID", value.sourceRepositoryDID),
        ("Trigger inputs", value.inputs.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")),
      ]
    case .unknown(let type, _):
      return [("Trigger type", type)]
    }
  }

  fileprivate func workflowFields(
    _ workflows: [PipelineWorkflow]
  ) -> [(label: String, value: String?)] {
    workflows.enumerated().flatMap { index, workflow in
      let name = "Workflow \(index + 1)"
      return [
        ("\(name) ID", workflow.id),
        ("\(name) name", workflow.name),
        ("\(name) status", workflow.status.rawValue),
        ("\(name) started", workflow.startedAt?.rawValue),
        ("\(name) finished", workflow.finishedAt?.rawValue),
        ("\(name) error", workflow.error),
      ]
    }
  }
}

private enum PipelineCommandError: Error {
  case invalidPipelineURI(String)
}

private struct PipelineWorkflowState: Equatable {
  let id: String
  let status: PipelineWorkflowStatus

  init(_ workflow: PipelineWorkflow) {
    self.id = workflow.id
    self.status = workflow.status
  }
}

struct PipelineWatchFailure: Error, Equatable, Sendable {
  let pipelineID: String
  let workflows: [PipelineWorkflow]

  var diagnostic: String {
    let summary = workflows.map { "\($0.name):\($0.status.rawValue)" }.joined(separator: ", ")
    return "pipeline \(pipelineID) finished unsuccessfully (\(summary))"
  }
}
