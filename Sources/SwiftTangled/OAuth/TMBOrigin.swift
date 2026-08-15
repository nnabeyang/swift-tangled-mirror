import Foundation

public struct TMBOrigin: Equatable, Hashable, Sendable {
  public let url: URL

  public init(_ value: String) throws {
    guard let url = URL(string: value) else {
      throw TMBClientError.invalidOrigin
    }
    try self.init(url)
  }

  public init(_ url: URL) throws {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      let host = components.host,
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else {
      throw TMBClientError.invalidOrigin
    }
    components.scheme = "https"
    components.host = host.lowercased()
    components.path = ""
    guard let canonical = components.url else {
      throw TMBClientError.invalidOrigin
    }
    self.url = canonical
  }
}
