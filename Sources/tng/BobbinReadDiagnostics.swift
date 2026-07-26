import SwiftTangled

enum BobbinCoverageState: Equatable, Sendable {
  case available(BobbinCoverage)
  case unavailable
}

func readBobbinCoverage(
  using load: @Sendable () async throws -> BobbinCoverage
) async throws -> BobbinCoverageState {
  do {
    return .available(try await load())
  } catch is CancellationError {
    throw CancellationError()
  } catch {
    return .unavailable
  }
}

struct BobbinReadDiagnostics: Sendable {
  let coverage: BobbinCoverageState
  let initialPageIsEmpty: Bool
  let authoritativeChanges: Int

  init(
    coverage: BobbinCoverageState,
    initialPageIsEmpty: Bool = false,
    authoritativeChanges: Int = 0
  ) {
    self.coverage = coverage
    self.initialPageIsEmpty = initialPageIsEmpty
    self.authoritativeChanges = authoritativeChanges
  }

  var stderr: String {
    var messages: [String] = []
    switch coverage {
    case .available(let coverage) where !coverage.ready:
      messages.append(
        "Bobbin index coverage is not ready "
          + "(processed \(coverage.eventsProcessed) events through cursor \(coverage.lastCursor)); "
          + "results may be incomplete."
      )
    case .unavailable:
      messages.append(
        "Could not determine Bobbin index coverage; results may be incomplete."
      )
    case .available:
      break
    }
    if initialPageIsEmpty {
      messages.append(
        "Bobbin returned no results; recent records may not be indexed yet."
      )
    }
    if authoritativeChanges > 0 {
      messages.append(
        "Merged \(authoritativeChanges) authoritative PDS "
          + (authoritativeChanges == 1 ? "record" : "records")
          + " not reflected by Bobbin."
      )
    }
    return messages.map { "warning: \($0)\n" }.joined()
  }
}
