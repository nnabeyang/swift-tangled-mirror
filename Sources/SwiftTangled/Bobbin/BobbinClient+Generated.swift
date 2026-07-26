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

  /// Decode-and-transform used by list endpoints where one malformed record must not
  /// abort the whole page. Failures are logged and dropped.
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
