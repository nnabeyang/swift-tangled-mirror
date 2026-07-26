import Foundation
import Testing

@testable import SwiftTangled

@Test func versionIsExposed() {
  #expect(SwiftTangled.version == "0.1.2")
}

@Test func tangledErrorCasesArePatternMatchable() {
  let error: TangledError = .serverStatus(503, "unavailable")
  switch error {
  case .serverStatus(let code, let message):
    #expect(code == 503)
    #expect(message == "unavailable")
  default:
    Issue.record("Unexpected error case")
  }
}
