import Foundation
import OAuth4Swift

@testable import SwiftTangled

enum SessionStoreTestHelpers {
  static func makeStoredSession(
    did: String = "did:plc:testalice",
    handle: String = "alice.test",
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
      "scopes": ["atproto"],
    ]
    let archiveJSON: [String: Any] = [
      "clientId": "https://example.com/client-metadata.json",
      "dPopKey": NSNull(),
      "issuingServer": "https://bsky.social",
      "grantScopes": ["atproto"],
      "tokenState": tokenStateJSON,
    ]
    let data = try JSONSerialization.data(withJSONObject: archiveJSON)
    let archive = try JSONDecoder().decode(OAuth.SessionState.Archive.self, from: data)
    return StoredSession(did: did, handle: handle, archive: archive)
  }
}
