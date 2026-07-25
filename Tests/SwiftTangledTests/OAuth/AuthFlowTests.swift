import Testing

@testable import SwiftTangled

@Test func authFlowThrowsForInvalidHandle() async {
  let flow = AuthFlow()
  await #expect(throws: TangledError.self) {
    _ = try await flow.login(handle: "not a handle")
  }
}
