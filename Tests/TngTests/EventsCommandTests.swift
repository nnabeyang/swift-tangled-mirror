import Foundation
import SwiftTangled
import Testing

@testable import tng

@Suite struct EventsCommandTests {
  @Test func parsesFiltersCursorAndJSONOutput() throws {
    let command = try EventsWatchCommand.parse([
      "--collection", "sh.tangled.repo.pull",
      "--collection", "sh.tangled.feed.comment",
      "--did", "did:plc:alice",
      "--did", "did:web:example.com",
      "--cursor", "123456",
      "--json",
    ])

    #expect(command.collection == ["sh.tangled.repo.pull", "sh.tangled.feed.comment"])
    #expect(command.did == ["did:plc:alice", "did:web:example.com"])
    #expect(command.cursor == 123_456)
    #expect(command.json)
  }

  @Test func rejectsInvalidFiltersAndCursor() {
    #expect(throws: (any Error).self) {
      _ = try EventsWatchCommand.parse(["--did", "alice.example"])
    }
    #expect(throws: (any Error).self) {
      _ = try EventsWatchCommand.parse(["--cursor", "-1"])
    }
    #expect(throws: (any Error).self) {
      _ = try EventsWatchCommand.parse(
        Array(repeating: ["--collection", "sh.tangled.repo.pull"], count: 101).flatMap {
          $0
        }
      )
    }
  }

  @Test func streamsHumanEventsAndReconnectDiagnostic() async throws {
    let recorder = EventsCommandRecorder()
    let events = [
      sampleEvent(timeUS: 100, collection: "sh.tangled.repo.pull", rkey: "3pull"),
      sampleEvent(timeUS: 101, collection: "sh.tangled.feed.comment", rkey: "3comment"),
    ]
    let service = EventsCommandService(
      dependencies: EventsCommandDependencies { options, stateHandler in
        recorder.record(options)
        stateHandler(
          .reconnecting(
            cursor: 99,
            attempt: 2,
            delay: 0.5,
            reason: "connection closed\nretrying"
          )
        )
        return finishedStream(events)
      },
      writer: recorder.writer
    )

    try await service.watch(
      collections: ["sh.tangled.repo.pull", "sh.tangled.feed.comment"],
      dids: ["did:plc:alice"],
      cursor: 50,
      json: false
    )

    #expect(
      recorder.stdout
        == """
        100\tdid:plc:alice\tcommit\tcreate\tsh.tangled.repo.pull\t3pull
        101\tdid:plc:alice\tcommit\tcreate\tsh.tangled.feed.comment\t3comment
        """ + "\n"
    )
    #expect(
      recorder.stderr
        == "Reconnecting Jetstream in 0.50s (attempt 2, cursor 99): connection closed retrying\n"
    )
    #expect(
      recorder.options
        == JetstreamOptions(
          wantedCollections: ["sh.tangled.repo.pull", "sh.tangled.feed.comment"],
          wantedDIDs: ["did:plc:alice"],
          cursor: 50
        )
    )
  }

  @Test func defaultsCollectionAndStreamsNDJSON() async throws {
    let recorder = EventsCommandRecorder()
    let events = [
      sampleEvent(timeUS: 200, collection: "sh.tangled.repo.issue", rkey: "3issue"),
      sampleEvent(timeUS: 201, collection: "sh.tangled.repo.pull", rkey: "3pull"),
    ]
    let service = EventsCommandService(
      dependencies: EventsCommandDependencies { options, _ in
        recorder.record(options)
        return finishedStream(events)
      },
      writer: recorder.writer
    )

    try await service.watch(collections: [], dids: [], cursor: nil, json: true)

    let lines = recorder.stdout.split(separator: "\n")
    #expect(lines.count == 2)
    let decoded = try lines.map {
      try JSONDecoder().decode(TangledEvent.self, from: Data($0.utf8))
    }
    #expect(decoded == events)
    #expect(recorder.options?.wantedCollections == ["sh.tangled.*"])
    #expect(recorder.stderr.isEmpty)
  }

  @Test func propagatesTerminalFailureAndCancelsStream() async throws {
    let failureService = EventsCommandService(
      dependencies: EventsCommandDependencies { _, _ in
        AsyncThrowingStream { continuation in
          continuation.finish(throwing: TangledError.decoding(TestFailure()))
        }
      },
      writer: EventsCommandRecorder().writer
    )
    await #expect(throws: TangledError.self) {
      try await failureService.watch(collections: [], dids: [], cursor: nil, json: false)
    }

    let recorder = EventsCommandRecorder()
    let cancellationService = EventsCommandService(
      dependencies: EventsCommandDependencies { _, _ in
        AsyncThrowingStream { continuation in
          continuation.onTermination = { _ in recorder.recordCancellation() }
        }
      },
      writer: recorder.writer
    )
    let task = Task {
      try await cancellationService.watch(
        collections: [],
        dids: [],
        cursor: nil,
        json: false
      )
    }
    await Task.yield()
    task.cancel()
    try await task.value
    for _ in 0 ..< 100 where recorder.cancellations == 0 {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(recorder.cancellations == 1)
  }
}

private func sampleEvent(timeUS: Int64, collection: String, rkey: String) -> TangledEvent {
  TangledEvent(
    did: "did:plc:alice",
    timeUS: timeUS,
    kind: .commit,
    commit: JetstreamCommit(
      rev: "3rev",
      operation: .create,
      collection: collection,
      rkey: rkey,
      record: .object(["title": .string("Test")]),
      cid: "bafy"
    )
  )
}

private func finishedStream(_ events: [TangledEvent]) -> TangledEventStream {
  AsyncThrowingStream { continuation in
    for event in events {
      continuation.yield(event)
    }
    continuation.finish()
  }
}

private struct TestFailure: Error {}

private final class EventsCommandRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var standardOutput = Data()
  private var standardError = Data()
  private var recordedOptions: JetstreamOptions?
  private var cancellationCount = 0

  var writer: CLIStreamWriter {
    CLIStreamWriter(
      stdout: { [self] data in
        lock.withLock { standardOutput.append(data) }
      },
      stderr: { [self] data in
        lock.withLock { standardError.append(data) }
      }
    )
  }

  var stdout: String {
    lock.withLock { String(decoding: standardOutput, as: UTF8.self) }
  }

  var stderr: String {
    lock.withLock { String(decoding: standardError, as: UTF8.self) }
  }

  var options: JetstreamOptions? {
    lock.withLock { recordedOptions }
  }

  var cancellations: Int {
    lock.withLock { cancellationCount }
  }

  func record(_ options: JetstreamOptions) {
    lock.withLock { recordedOptions = options }
  }

  func recordCancellation() {
    lock.withLock { cancellationCount += 1 }
  }
}
