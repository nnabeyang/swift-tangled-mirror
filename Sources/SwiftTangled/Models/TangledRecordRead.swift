public enum TangledRecordSource: String, Codable, Equatable, Hashable, Sendable {
  case pds
  case bobbinFallback
}

public struct TangledRecordRead<Value: Sendable>: Sendable {
  public let record: TangledRecord<Value>
  public let source: TangledRecordSource

  public init(record: TangledRecord<Value>, source: TangledRecordSource) {
    self.record = record
    self.source = source
  }
}

extension TangledRecordRead: Equatable where Value: Equatable {}
extension TangledRecordRead: Hashable where Value: Hashable {}
extension TangledRecordRead: Codable where Value: Codable {}
