import Foundation
import Logging
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
  static let recordDecodeLogger = Logger(label: "SwiftTangled.Bobbin.RecordDecode")

  func generatedQuery<Response: Sendable>(
    _ operation: () async throws -> Response
  ) async throws -> Response {
    do {
      return try await operation()
    } catch let error as DecodingError {
      throw TangledError.decoding(error)
    }
  }

  func generatedRecord<Value: Decodable & Sendable>(
    uri: FormatString<ATURI>,
    cid: FormatString<LexLink>?,
    value: UnknownATPValue,
    as type: Value.Type = Value.self
  ) throws -> BobbinRecord<Value> {
    BobbinRecord(
      uri: uri.rawValue,
      cid: cid?.rawValue,
      value: try decodeGenerated(value, as: type)
    )
  }

  /// Decodes list records independently so one malformed item does not abort the page.
  func tolerantGeneratedRecord<Value: Decodable & Sendable, Result>(
    uri: FormatString<ATURI>,
    cid: FormatString<LexLink>?,
    value: UnknownATPValue,
    as type: Value.Type = Value.self,
    transform: (BobbinRecord<Value>) throws -> Result
  ) -> Result? {
    do {
      let record: BobbinRecord<Value> = try generatedRecord(
        uri: uri,
        cid: cid,
        value: value,
        as: type
      )
      return try transform(record)
    } catch {
      Self.recordDecodeLogger.warning(
        "skipping malformed record",
        metadata: [
          "type": .string(String(describing: type)),
          "uri": .string(uri.rawValue),
          "error": .string(String(describing: error)),
        ]
      )
      return nil
    }
  }

  /// Runs an arbitrary list-record decode without aborting the page.
  func tolerantDecode<Result>(
    uri: FormatString<ATURI>,
    _ operation: () throws -> Result
  ) -> Result? {
    do {
      return try operation()
    } catch {
      Self.recordDecodeLogger.warning(
        "skipping malformed record",
        metadata: [
          "uri": .string(uri.rawValue),
          "error": .string(String(describing: error)),
        ]
      )
      return nil
    }
  }

  func decodeGenerated<Value: Decodable & Sendable>(
    _ value: UnknownATPValue,
    as type: Value.Type = Value.self
  ) throws -> Value {
    do {
      let data = try JSONEncoder().encode(value)
      let decoder = JSONDecoder()
      decoder.userInfo[.atprotoLexiconDecodingMode] = LexiconDecodingMode.permissive
      return try decoder.decode(type, from: data)
    } catch {
      throw TangledError.decoding(error)
    }
  }
}
