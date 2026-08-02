import Foundation
import SwiftAtproto
import TangledLexicons

extension BobbinClient {
  func percentEncodedQueryItem(_ item: URLQueryItem) -> URLQueryItem {
    URLQueryItem(
      name: percentEncodeQueryComponent(item.name),
      value: item.value.map(percentEncodeQueryComponent)
    )
  }

  private func percentEncodeQueryComponent(_ value: String) -> String {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._"
    )
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  func validateGitRepositoryURI(_ value: String) throws(TangledError) {
    try requireNonempty(value, name: "repository URI")
    guard let uri = FormatString<ATURI>(rawValue: value).typed,
      uri.collection?.rawValue == Sh.Tangled.Repo.nsId
    else {
      throw TangledError.invalidRequest(
        "repository URI must be a \(Sh.Tangled.Repo.nsId) AT URI"
      )
    }
  }

  func requireNonempty(_ value: String, name: String) throws(TangledError) {
    guard !value.isEmpty else {
      throw TangledError.invalidRequest("\(name) must not be empty")
    }
  }

  func validateBatch(_ values: [String], name: String) throws(TangledError) {
    guard values.allSatisfy({ !$0.isEmpty }) else {
      throw TangledError.invalidRequest("\(name) must not contain an empty value")
    }
  }
}

struct BobbinRecord<Value: Decodable & Sendable>: Decodable, Sendable {
  let uri: String
  let cid: String?
  let value: Value
}
