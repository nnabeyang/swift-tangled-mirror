import Foundation
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
  public func labelDefinitions(
    scope: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<LabelDefinition>> {
    try requireNonempty(scope, name: "label definition scope")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await LabelListDefinitions(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.LabelListDefinitions_Order(rawValue: order.rawValue),
        subject: scope
      )
    }
    let items = try response.items.map {
      let record: BobbinRecord<WireLabelDefinition> = try generatedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value
      )
      return record.labelDefinitionRecord
    }
    return Page(items: items, cursor: response.cursor)
  }

  public func labelDefinitionCount(scope: String) async throws -> CountSummary {
    try requireNonempty(scope, name: "label definition scope")
    let response = try await generatedQuery {
      try await LabelCountDefinitions(subject: scope)
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func labelOperations(
    subjectURI: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<LabelOperation>> {
    try requireNonempty(subjectURI, name: "label operation subject URI")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await LabelListOps(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.LabelListOps_Order(rawValue: order.rawValue),
        subject: subjectURI
      )
    }
    let items = try response.items.map {
      let record: BobbinRecord<WireLabelOperation> = try generatedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value
      )
      return record.labelOperationRecord
    }
    return Page(items: items, cursor: response.cursor)
  }

  public func labelOperations(
    authorDID: String,
    cursor: String? = nil,
    limit: Int? = nil,
    order: BobbinSortOrder = .descending
  ) async throws -> Page<TangledRecord<LabelOperation>> {
    try requireNonempty(authorDID, name: "label operation author DID")
    try validateLimit(limit)
    let response = try await generatedQuery {
      try await LabelListOpsBy(
        cursor: cursor,
        limit: limit,
        order: Sh.Tangled.LabelListOpsBy_Order(rawValue: order.rawValue),
        subject: FormatString<DID>(rawValue: authorDID)
      )
    }
    let items = try response.items.map {
      let record: BobbinRecord<WireLabelOperation> = try generatedRecord(
        uri: $0.uri,
        cid: $0.cid,
        value: $0.value
      )
      return record.labelOperationRecord
    }
    return Page(items: items, cursor: response.cursor)
  }

  public func labelOperationCount(subjectURI: String) async throws -> CountSummary {
    try requireNonempty(subjectURI, name: "label operation subject URI")
    let response = try await generatedQuery {
      try await LabelCountOps(subject: subjectURI)
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }

  public func labelOperationCount(authorDID: String) async throws -> CountSummary {
    try requireNonempty(authorDID, name: "label operation author DID")
    let response = try await generatedQuery {
      try await LabelCountOpsBy(subject: FormatString<DID>(rawValue: authorDID))
    }
    return CountSummary(count: response.count, distinctAuthors: response.distinctAuthors)
  }
}

private struct WireLabelDefinition: Decodable, Sendable {
  let name: String
  let valueType: WireLabelValueType
  let scope: [String]
  let color: String?
  let createdAt: FormatString<Date>
  let multiple: Bool?
}

private struct WireLabelValueType: Decodable, Sendable {
  let kind: String
  let format: String
  let allowedValues: [String]?

  enum CodingKeys: String, CodingKey {
    case kind = "type"
    case format
    case allowedValues = "enum"
  }
}

private struct WireLabelOperation: Decodable, Sendable {
  let subject: String
  let add: [WireLabelOperand]
  let delete: [WireLabelOperand]
  let performedAt: FormatString<Date>
}

private struct WireLabelOperand: Decodable, Sendable {
  let key: String
  let value: String
}

extension BobbinRecord where Value == WireLabelDefinition {
  fileprivate var labelDefinitionRecord: TangledRecord<LabelDefinition> {
    TangledRecord(
      uri: uri,
      cid: cid,
      value: LabelDefinition(
        name: value.name,
        valueType: LabelValueType(
          kind: LabelValueKind(rawValue: value.valueType.kind),
          format: LabelValueFormat(rawValue: value.valueType.format),
          allowedValues: value.valueType.allowedValues ?? []
        ),
        scope: value.scope,
        color: value.color,
        createdAt: value.createdAt,
        allowsMultipleValues: value.multiple
      )
    )
  }
}

extension BobbinRecord where Value == WireLabelOperation {
  fileprivate var labelOperationRecord: TangledRecord<LabelOperation> {
    TangledRecord(
      uri: uri,
      cid: cid,
      value: LabelOperation(
        subjectURI: value.subject,
        additions: value.add.map(\.labelOperand),
        deletions: value.delete.map(\.labelOperand),
        performedAt: value.performedAt
      )
    )
  }
}

extension WireLabelOperand {
  fileprivate var labelOperand: LabelOperand {
    LabelOperand(definitionURI: key, value: value)
  }
}
