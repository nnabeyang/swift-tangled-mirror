import Foundation
import SwiftTangled

typealias TangledEventStream = AsyncThrowingStream<TangledEvent, any Error>

struct EventsCommandDependencies: Sendable {
  let events:
    @Sendable (
      JetstreamOptions,
      @escaping @Sendable (JetstreamConnectionState) -> Void
    ) -> TangledEventStream

  static let live = EventsCommandDependencies(
    events: { options, stateHandler in
      JetstreamClient(onConnectionStateChange: stateHandler).events(options: options)
    }
  )
}

struct CLIStreamWriter: Sendable {
  let stdout: @Sendable (Data) -> Void
  let stderr: @Sendable (Data) -> Void

  static let live = CLIStreamWriter(
    stdout: { FileHandle.standardOutput.write($0) },
    stderr: { FileHandle.standardError.write($0) }
  )

  func writeStandardOutput(_ string: String) {
    guard !string.isEmpty else { return }
    stdout(Data(string.utf8))
  }

  func writeStandardError(_ string: String) {
    guard !string.isEmpty else { return }
    stderr(Data(string.utf8))
  }
}

struct EventsCommandService: Sendable {
  private let dependencies: EventsCommandDependencies
  private let formatter: CLIFormatter
  private let writer: CLIStreamWriter

  init(
    dependencies: EventsCommandDependencies = .live,
    formatter: CLIFormatter = .plain,
    writer: CLIStreamWriter = .live
  ) {
    self.dependencies = dependencies
    self.formatter = formatter
    self.writer = writer
  }

  func watch(
    collections: [String],
    dids: [String],
    cursor: Int64?,
    json: Bool
  ) async throws {
    let options = JetstreamOptions(
      wantedCollections: collections.isEmpty ? ["sh.tangled.*"] : collections,
      wantedDIDs: dids,
      cursor: cursor
    )
    let stream = dependencies.events(options) { state in
      guard case .reconnecting(let cursor, let attempt, let delay, let reason) = state else {
        return
      }
      writer.writeStandardError(
        reconnectDiagnostic(cursor: cursor, attempt: attempt, delay: delay, reason: reason)
      )
    }

    for try await event in stream {
      writer.writeStandardOutput(try json ? formatter.jsonLine(event) : format(event))
    }
  }

  private func format(_ event: TangledEvent) -> String {
    [
      String(event.timeUS),
      event.did,
      event.kind.rawValue,
      event.commit?.operation.rawValue,
      event.commit?.collection,
      event.commit?.rkey,
    ].map(formatter.cell).joined(separator: "\t") + "\n"
  }

  private func reconnectDiagnostic(
    cursor: Int64?,
    attempt: Int,
    delay: TimeInterval,
    reason: String
  ) -> String {
    let seconds = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), delay)
    return
      "Reconnecting Jetstream in \(seconds)s"
      + " (attempt \(attempt), cursor \(cursor.map(String.init) ?? "-")):"
      + " \(formatter.cell(reason))\n"
  }
}
