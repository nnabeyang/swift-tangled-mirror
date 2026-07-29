import Foundation
import SwiftAtproto
import TangledLexicons

extension SpindleClient {
  package func triggerPipeline(
    repositoryDID: String,
    trigger: PipelineTrigger,
    workflows: [String],
    token: String
  ) async throws -> String {
    let generatedTrigger: Sh.Tangled.CiTriggerPipeline_Input_Trigger
    switch trigger {
    case .manual(let value):
      generatedTrigger = .ciTriggerManual(
        try Sh.Tangled.CiTrigger_Manual.make(
          inputs: value.inputs.map {
            Sh.Tangled.CiTrigger_Pair(key: $0.key, value: $0.value)
          },
          ref: value.ref,
          sha: value.sha,
          sourceRepo: value.sourceRepositoryDID.map(FormatString<DID>.init(rawValue:))
        )
      )
    case .pullRequest(let value):
      generatedTrigger = .ciTriggerPullRequest(
        try Sh.Tangled.CiTrigger_PullRequest.make(
          pull: value.pullRequestURI.map(FormatString<ATURI>.init(rawValue:)),
          sourceBranch: value.sourceBranch,
          sourceRepo: value.sourceRepositoryDID.map(FormatString<DID>.init(rawValue:)),
          sourceSha: value.sourceSHA,
          targetBranch: value.targetBranch
        )
      )
    case .push, .unknown:
      throw TangledError.invalidRequest("pipeline retry requires a manual or pull-request trigger")
    }

    let client = HTTPXRPCClient(
      baseURL: baseURL,
      transport: transport,
      bearerToken: token
    )
    let output = try await client.CiTriggerPipeline(
      input: Sh.Tangled.CiTriggerPipeline_Input(
        repo: FormatString(rawValue: repositoryDID),
        trigger: generatedTrigger,
        workflows: workflows
      )
    )
    let uri = output.pipeline.rawValue
    guard let parsed = output.pipeline.typed,
      ["sh.tangled.ci.pipeline", "sh.tangled.pipeline"].contains(
        parsed.collection?.rawValue
      ),
      parsed.rkey != nil
    else {
      throw TangledError.decoding(PipelineRetryError.invalidPipelineURI(uri))
    }
    return uri
  }
}

private enum PipelineRetryError: Error, Sendable {
  case invalidPipelineURI(String)
}
