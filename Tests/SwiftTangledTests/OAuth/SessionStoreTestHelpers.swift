import Foundation
import OAuth4Swift

@testable import SwiftTangled

enum SessionStoreTestHelpers {
  static func makeStoredSession(
    did: String = "did:plc:testalice",
    handle: String = "alice.test",
    profile: AuthenticationProfile? = nil,
    clientID: String = "https://example.com/client-metadata.json",
    scopes: [String] = ["atproto"],
    includeDPoPKey: Bool = false,
    accessToken: String = "test-access",
    refreshToken: String? = "test-refresh",
    expiry: Date? = nil
  ) throws -> StoredSession {
    let tokenStateJSON: [String: Any] = [
      "accessToken": [
        "value": accessToken,
        "expiry": expiry.map { $0.timeIntervalSinceReferenceDate as Any } as Any?,
      ].compactMapValues { $0 },
      "refreshToken": refreshToken.map {
        [
          "value": $0,
          "expiry": NSNull(),
        ]
      } as Any? ?? NSNull(),
      "scopes": scopes,
    ]
    let dpopKey: Any =
      if includeDPoPKey {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(OAuth.DPoP.Key.generateP256()))
      } else {
        NSNull()
      }
    let archiveJSON: [String: Any] = [
      "clientId": clientID,
      "dPopKey": dpopKey,
      "issuingServer": "https://bsky.social",
      "grantScopes": scopes,
      "tokenState": tokenStateJSON,
    ]
    let data = try JSONSerialization.data(withJSONObject: archiveJSON)
    let archive = try JSONDecoder().decode(OAuth.SessionState.Archive.self, from: data)
    return StoredSession(did: did, handle: handle, profile: profile, archive: archive)
  }
}
