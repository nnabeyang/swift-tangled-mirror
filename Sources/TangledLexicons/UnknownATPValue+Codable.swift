import SwiftAtproto

private enum UnknownTypeCodingKeys: String, CodingKey {
  case type = "$type"
}

extension UnknownATPValue {
  public init(from decoder: any Decoder) throws {
    if let container = try? decoder.container(keyedBy: UnknownTypeCodingKeys.self),
      let typeName = try container.decodeIfPresent(String.self, forKey: .type)
    {
      if let type = Self.allTypes[typeName] {
        self = try .record(type.init(from: decoder))
      } else {
        self = try .record(UnknownRecord(from: decoder))
      }
    } else {
      self = try .any(AnyCodable(from: decoder))
    }
  }
}
