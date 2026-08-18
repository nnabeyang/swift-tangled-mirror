import Foundation
import OAuth4Swift

extension OAuth.SessionState.TokenState {
  // OAuth4Swift keeps TokenState.scopes internal. grantScopes is not a
  // substitute: it is what the grant requested, not what the last refresh authorized.
  var authorizedScopes: [String] {
    guard let data = try? JSONEncoder().encode(self),
      let probe = try? JSONDecoder().decode(ScopesProbe.self, from: data)
    else {
      return []
    }
    return probe.scopes
  }

  private struct ScopesProbe: Decodable {
    let scopes: [String]
  }
}
