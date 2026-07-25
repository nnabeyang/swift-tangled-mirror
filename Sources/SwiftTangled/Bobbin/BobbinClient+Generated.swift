import Foundation
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
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
