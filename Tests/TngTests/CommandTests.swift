import Testing

@testable import SwiftTangled

@Test func versionAlignsWithSDK() {
  #expect(SwiftTangled.version == "0.1.1")
}
