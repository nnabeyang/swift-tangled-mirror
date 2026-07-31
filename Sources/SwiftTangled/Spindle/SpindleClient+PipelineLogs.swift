import Foundation
import SwiftAtproto
import TangledLexicons

extension SpindleClient {
  public func pipelineLogs(
    pipelineID: String,
    workflows: [String] = []
  ) async throws -> AsyncThrowingStream<PipelineLogEvent, any Error> {
    let selectedWorkflows = try await validatePipelineLogRequest(
      pipelineID: pipelineID,
      workflows: workflows
    )
    let source = subscribe(
      Sh.Tangled.CiSubscribePipelineLogs.self,
      input: .init(
        pipeline: FormatString<TID>(rawValue: pipelineID),
        workflows: selectedWorkflows.isEmpty ? nil : selectedWorkflows
      )
    )

    return AsyncThrowingStream(
      bufferingPolicy: .bufferingOldest(Self.pipelineLogBufferCapacity)
    ) { continuation in
      let task = Task {
        do {
          for try await message in source {
            guard let event = pipelineLogEvent(from: message) else {
              continue
            }
            switch continuation.yield(event) {
            case .enqueued:
              break
            case .dropped:
              throw TangledError.transport(
                "pipeline log buffer overflow (limit: \(Self.pipelineLogBufferCapacity))"
              )
            case .terminated:
              throw CancellationError()
            @unknown default:
              throw TangledError.transport(
                "pipeline log buffer overflow (limit: \(Self.pipelineLogBufferCapacity))"
              )
            }
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch let error as Sh.Tangled.CiSubscribePipelineLogs.Error {
          continuation.finish(throwing: pipelineLogError(error))
        } catch let error as XRPCSubscriptionStreamError {
          continuation.finish(
            throwing: TangledError.transport(
              "invalid Spindle pipeline log stream: \(String(describing: error))"
            )
          )
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }
}

extension SpindleClient {
  private func validatePipelineLogRequest(
    pipelineID: String,
    workflows: [String]
  ) async throws -> [String] {
    let pipeline = try await pipeline(id: pipelineID)
    var selected: [String] = []
    var seen = Set<String>()
    let available = Set(pipeline.workflows.map(\.name))

    for workflow in workflows {
      guard !workflow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TangledError.invalidRequest("workflow must not be empty")
      }
      guard available.contains(workflow) else {
        throw TangledError.invalidRequest(
          "workflow not found in pipeline \(pipelineID): \(workflow)"
        )
      }
      if seen.insert(workflow).inserted {
        selected.append(workflow)
      }
    }
    return selected
  }

  func pipelineLogEvent(
    from message: Sh.Tangled.CiSubscribePipelineLogs.Message
  ) -> PipelineLogEvent? {
    switch message {
    case .ciSubscribePipelineLogsControl(let control):
      return .control(
        PipelineLogControl(
          time: control.time,
          workflow: control.workflow,
          step: control.step,
          content: control.content,
          command: control.command,
          status: control.status.map {
            PipelineLogControlStatus(rawValue: $0.rawValue)
          },
          kind: control.kind.map {
            PipelineLogControlKind(rawValue: $0.rawValue)
          }
        )
      )
    case .ciSubscribePipelineLogsData(let data):
      return .data(
        PipelineLogData(
          time: data.time,
          workflow: data.workflow,
          step: data.step,
          content: data.content,
          stream: PipelineLogStream(rawValue: data.stream.rawValue)
        )
      )
    case ._other:
      return nil
    }
  }

  private func pipelineLogError(
    _ error: Sh.Tangled.CiSubscribePipelineLogs.Error
  ) -> TangledError {
    switch error {
    case .invalidrequest(let message):
      return .invalidRequest(message ?? "Spindle rejected the pipeline log request")
    case .workflownotfound(let message):
      return .invalidRequest(message ?? "Spindle could not find the requested workflow")
    case .unexpected(let code, let message):
      let detail = [code, message].compactMap { $0 }.joined(separator: ": ")
      return .upstreamFailed(detail.isEmpty ? "Spindle pipeline log subscription failed" : detail)
    }
  }
}
