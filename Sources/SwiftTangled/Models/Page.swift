public struct Page<Element: Sendable>: Sendable {
  public let items: [Element]
  public let cursor: String?

  public init(items: [Element], cursor: String? = nil) {
    self.items = items
    self.cursor = cursor
  }
}

extension Page: Equatable where Element: Equatable {}
extension Page: Codable where Element: Codable {}

public struct CountSummary: Codable, Equatable, Sendable {
  public let count: Int
  public let distinctAuthors: Int?

  public init(count: Int, distinctAuthors: Int? = nil) {
    self.count = count
    self.distinctAuthors = distinctAuthors
  }
}
