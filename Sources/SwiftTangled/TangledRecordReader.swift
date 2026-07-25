public struct TangledRecordReader: Sendable {
  private let pdsClient: PDSRecordClient
  private let bobbinClient: BobbinClient

  public init(
    pdsClient: PDSRecordClient = PDSRecordClient(),
    bobbinClient: BobbinClient = BobbinClient()
  ) {
    self.pdsClient = pdsClient
    self.bobbinClient = bobbinClient
  }

  public func repository(uri: String) async throws -> TangledRecordRead<Repository> {
    try await read(
      fromPDS: { try await pdsClient.repository(uri: uri) },
      fromBobbin: { try await bobbinClient.repository(uri: uri) }
    )
  }

  public func issue(uri: String) async throws -> TangledRecordRead<Issue> {
    try await read(
      fromPDS: { try await pdsClient.issue(uri: uri) },
      fromBobbin: { try await bobbinClient.issue(uri: uri) }
    )
  }

  public func pullRequest(uri: String) async throws -> TangledRecordRead<PullRequest> {
    try await read(
      fromPDS: { try await pdsClient.pullRequest(uri: uri) },
      fromBobbin: { try await bobbinClient.pullRequest(uri: uri) }
    )
  }

  public func artifact(uri: String) async throws -> TangledRecordRead<Artifact> {
    TangledRecordRead(
      record: try await pdsClient.artifact(uri: uri),
      source: .pds
    )
  }
}

extension TangledRecordReader {
  private func read<Value: Sendable>(
    fromPDS: () async throws -> TangledRecord<Value>,
    fromBobbin: () async throws -> TangledRecord<Value>
  ) async throws -> TangledRecordRead<Value> {
    do {
      return TangledRecordRead(record: try await fromPDS(), source: .pds)
    } catch is CancellationError {
      throw CancellationError()
    } catch let pdsError as TangledError {
      guard shouldFallback(after: pdsError) else {
        throw pdsError
      }
      do {
        return TangledRecordRead(
          record: try await fromBobbin(),
          source: .bobbinFallback
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw pdsError
      }
    }
  }

  private func shouldFallback(after error: TangledError) -> Bool {
    switch error {
    case .network, .transport, .handleNotResolved, .rateLimited, .serviceUnavailable:
      true
    case .serverStatus(let statusCode, _):
      statusCode >= 500
    default:
      false
    }
  }
}
