import SwiftTangled
import Testing

@testable import tng

@Suite struct BobbinReadDiagnosticsTests {
  @Test func healthyNonemptyReadIsSilent() {
    let diagnostics = BobbinReadDiagnostics(
      coverage: .available(.init(ready: true, eventsProcessed: 10, lastCursor: 12))
    )

    #expect(diagnostics.stderr.isEmpty)
  }

  @Test func reportsWarmingUnavailableEmptyAndAuthoritativeReads() {
    let warming = BobbinReadDiagnostics(
      coverage: .available(.init(ready: false, eventsProcessed: 10, lastCursor: 12))
    )
    #expect(warming.stderr.contains("coverage is not ready"))
    #expect(warming.stderr.contains("processed 10 events through cursor 12"))

    let unavailable = BobbinReadDiagnostics(coverage: .unavailable)
    #expect(unavailable.stderr.contains("Could not determine"))

    let emptyAndMerged = BobbinReadDiagnostics(
      coverage: .available(.init(ready: true, eventsProcessed: 10, lastCursor: 12)),
      initialPageIsEmpty: true,
      authoritativeChanges: 2
    )
    #expect(emptyAndMerged.stderr.contains("returned no results"))
    #expect(emptyAndMerged.stderr.contains("Merged 2 authoritative PDS records"))
  }

  @Test func coverageFailureIsDiagnosticButCancellationPropagates() async throws {
    let state = try await readBobbinCoverage {
      throw TangledError.transport("offline")
    }
    #expect(state == .unavailable)

    await #expect(throws: CancellationError.self) {
      _ = try await readBobbinCoverage {
        throw CancellationError()
      }
    }
  }
}
