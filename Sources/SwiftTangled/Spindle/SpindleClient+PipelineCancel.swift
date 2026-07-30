import SwiftAtproto
import TangledLexicons

package let pipelineCancelMethod = Sh.Tangled.CiCancelPipeline.id

extension SpindleClient {
  package func cancelPipeline(
    repositoryDID: String,
    pipelineID: String,
    workflows: [String]?,
    token: String
  ) async throws {
    guard FormatString<DID>(rawValue: repositoryDID).typed != nil else {
      throw TangledError.invalidRequest("repository DID must be a valid DID")
    }
    guard (try? TID(string: pipelineID)) != nil else {
      throw TangledError.invalidRequest("pipeline ID must be a valid TID")
    }
    if let workflows,
      workflows.contains(where: {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    {
      throw TangledError.invalidRequest("workflow name must not be empty")
    }

    let client = HTTPXRPCClient(
      baseURL: baseURL,
      transport: transport,
      bearerToken: token
    )
    _ = try await client.CiCancelPipeline(
      input: Sh.Tangled.CiCancelPipeline_Input(
        pipeline: FormatString(rawValue: pipelineID),
        repo: FormatString(rawValue: repositoryDID),
        workflows: workflows
      )
    )
  }
}
