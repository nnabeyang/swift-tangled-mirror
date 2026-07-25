public struct TangledRecord<Value: Sendable>: Sendable {
  public let uri: String
  public let cid: String?
  public let value: Value

  public init(uri: String, cid: String? = nil, value: Value) {
    self.uri = uri
    self.cid = cid
    self.value = value
  }
}

extension TangledRecord: Equatable where Value: Equatable {}
extension TangledRecord: Hashable where Value: Hashable {}
extension TangledRecord: Codable where Value: Codable {}
