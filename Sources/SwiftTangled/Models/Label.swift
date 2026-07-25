import Foundation
import SwiftAtproto

public struct LabelValueKind: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let null = LabelValueKind(rawValue: "null")
  public static let boolean = LabelValueKind(rawValue: "boolean")
  public static let integer = LabelValueKind(rawValue: "integer")
  public static let string = LabelValueKind(rawValue: "string")

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try String(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try rawValue.encode(to: encoder)
  }
}

public struct LabelValueFormat: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let any = LabelValueFormat(rawValue: "any")
  public static let did = LabelValueFormat(rawValue: "did")
  public static let nsid = LabelValueFormat(rawValue: "nsid")

  public init(from decoder: any Decoder) throws {
    self.init(rawValue: try String(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try rawValue.encode(to: encoder)
  }
}

public struct LabelValueType: Codable, Equatable, Hashable, Sendable {
  public let kind: LabelValueKind
  public let format: LabelValueFormat
  public let allowedValues: [String]

  public init(
    kind: LabelValueKind,
    format: LabelValueFormat,
    allowedValues: [String] = []
  ) {
    self.kind = kind
    self.format = format
    self.allowedValues = allowedValues
  }
}

public struct LabelDefinition: Codable, Equatable, Hashable, Sendable {
  public let name: String
  public let valueType: LabelValueType
  public let scope: [String]
  public let color: String?
  public let createdAt: FormatString<Date>
  public let allowsMultipleValues: Bool?

  public init(
    name: String,
    valueType: LabelValueType,
    scope: [String],
    color: String? = nil,
    createdAt: FormatString<Date>,
    allowsMultipleValues: Bool? = nil
  ) {
    self.name = name
    self.valueType = valueType
    self.scope = scope
    self.color = color
    self.createdAt = createdAt
    self.allowsMultipleValues = allowsMultipleValues
  }
}

public struct LabelOperand: Codable, Equatable, Hashable, Sendable {
  public let definitionURI: String
  public let value: String

  public init(definitionURI: String, value: String) {
    self.definitionURI = definitionURI
    self.value = value
  }
}

public struct LabelOperation: Codable, Equatable, Hashable, Sendable {
  public let subjectURI: String
  public let additions: [LabelOperand]
  public let deletions: [LabelOperand]
  public let performedAt: FormatString<Date>

  public init(
    subjectURI: String,
    additions: [LabelOperand],
    deletions: [LabelOperand],
    performedAt: FormatString<Date>
  ) {
    self.subjectURI = subjectURI
    self.additions = additions
    self.deletions = deletions
    self.performedAt = performedAt
  }
}
