import Foundation
import Testing

@testable import SwiftTangled

@Suite struct StoredSessionProfileTests {
  @Test func legacySessionWithoutProfileStillDecodes() throws {
    let session = try SessionStoreTestHelpers.makeStoredSession(
      storedClientID: "https://client.example/metadata.json"
    )
    let encoded = try JSONEncoder().encode(session)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "profile")
    object.removeValue(forKey: "clientId")
    let legacy = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(StoredSession.self, from: legacy)

    #expect(decoded.did == session.did)
    #expect(decoded.profile == nil)
    #expect(decoded.clientID == nil)
    #expect(decoded.resolvedClientID == legacyTangledCLIClientID)
  }

  @Test func profileRoundTripsWithoutCredentialProjection() throws {
    let session = try SessionStoreTestHelpers.makeStoredSession(
      profile: .ciReporting,
      storedClientID: "https://client.example/metadata.json"
    )
    let decoded = try JSONDecoder().decode(
      StoredSession.self,
      from: JSONEncoder().encode(session)
    )
    #expect(decoded.profile == .ciReporting)
    #expect(decoded.clientID == "https://client.example/metadata.json")
    #expect(decoded.resolvedClientID == "https://client.example/metadata.json")
  }
}
