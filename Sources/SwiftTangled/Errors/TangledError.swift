import Foundation

public enum TangledError: Error, Sendable {
  case notImplemented(String)
  case network(URLError)
  case transport(String)
  case decoding(any Error)
  case invalidRequest(String?)
  case unauthorized
  case insufficientScope(String)
  case notFound(String?)
  case rateLimited(retryAfter: TimeInterval?, message: String?)
  case upstreamFailed(String?)
  case serviceUnavailable(String?)
  case serverStatus(Int, String?)
  case oauthTimeout
  case oauthStateMismatch
  case oauthCancelled(String)
  case portBindFailure(String)
  case browserLaunchFailed(String)
  case handleNotResolved(String)
  case keychainFailure(Int32)
  case sessionStoreFailure(String)
}
