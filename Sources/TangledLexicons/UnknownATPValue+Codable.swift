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
        do {
          self = try .record(type.init(from: decoder))
        } catch {
          // The type is known but the payload violates its schema (e.g. an enum
          // value the lexicon does not accept). Fall back to UnknownRecord so a
          // single malformed item cannot fail the surrounding container. Callers
          // that need the typed value should re-decode and handle the error.
          self = try .record(UnknownRecord(from: decoder))
        }
      } else {
        self = try .record(UnknownRecord(from: decoder))
      }
    } else {
      self = try .any(AnyCodable(from: decoder))
    }
  }
}
