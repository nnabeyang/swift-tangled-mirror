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
      let record: BobbinRecord<Sh.Tangled.LabelDefinition> = try generatedRecord(
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
      let record: BobbinRecord<Sh.Tangled.LabelOp> = try generatedRecord(
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
      let record: BobbinRecord<Sh.Tangled.LabelOp> = try generatedRecord(
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

extension BobbinRecord where Value == Sh.Tangled.LabelDefinition {
  fileprivate var labelDefinitionRecord: TangledRecord<LabelDefinition> {
    TangledRecord(
      uri: uri,
      cid: cid,
      value: LabelDefinition(
        name: value.name,
        valueType: LabelValueType(
          kind: LabelValueKind(rawValue: value.valueType.type.rawValue),
          format: LabelValueFormat(rawValue: value.valueType.format.rawValue),
          allowedValues: value.valueType.enum ?? []
        ),
        scope: value.scope.map(\.rawValue),
        color: value.color,
        createdAt: value.createdAt,
        allowsMultipleValues: value.multiple
      )
    )
  }
}

extension BobbinRecord where Value == Sh.Tangled.LabelOp {
  fileprivate var labelOperationRecord: TangledRecord<LabelOperation> {
    TangledRecord(
      uri: uri,
      cid: cid,
      value: LabelOperation(
        subjectURI: value.subject.rawValue,
        additions: value.add.map(\.labelOperand),
        deletions: value.delete.map(\.labelOperand),
        performedAt: value.performedAt
      )
    )
  }
}

extension Sh.Tangled.LabelOp_Operand {
  fileprivate var labelOperand: LabelOperand {
    LabelOperand(definitionURI: key.rawValue, value: value)
  }
}
