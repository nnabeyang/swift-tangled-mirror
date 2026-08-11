import Foundation
import Testing

@testable import SwiftTangled

@Suite struct StoredSessionProfileTests {
  @Test func legacySessionWithoutProfileStillDecodes() throws {
    let session = try SessionStoreTestHelpers.makeStoredSession()
    let encoded = try JSONEncoder().encode(session)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "profile")
    let legacy = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(StoredSession.self, from: legacy)

    #expect(decoded.did == session.did)
    #expect(decoded.profile == nil)
  }

  @Test func profileRoundTripsWithoutCredentialProjection() throws {
    let session = try SessionStoreTestHelpers.makeStoredSession(profile: .ciReporting)
    let decoded = try JSONDecoder().decode(
      StoredSession.self,
      from: JSONEncoder().encode(session)
    )
    #expect(decoded.profile == .ciReporting)
  }
}
