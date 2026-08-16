import Testing

@testable import SwiftTangled

@Test func authFlowThrowsForInvalidHandle() async {
  let flow = AuthFlow()
  await #expect(throws: TangledError.self) {
    _ = try await flow.login(handle: "not a handle")
  }
}

@Test func loopbackClientRejectionProvidesHostedRecovery() {
  for code in ["invalid_client", "unauthorized_client", "invalid_request"] {
    #expect(
      loopbackClientRejectionMessage(errorCode: code)
        == "authorization server rejected the loopback OAuth client; retry with '--client-id <https URL>' to use hosted client metadata"
    )
  }
  #expect(loopbackClientRejectionMessage(errorCode: "temporarily_unavailable") == nil)
}
