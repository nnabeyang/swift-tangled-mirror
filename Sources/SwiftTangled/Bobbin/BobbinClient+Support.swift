import Foundation
import SwiftAtproto

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

  func validateGitRepositoryURI(_ value: String) throws {
    try requireNonempty(value, name: "repository URI")
    guard let uri = FormatString<ATURI>(rawValue: value).typed,
      uri.collection?.rawValue == "sh.tangled.repo"
    else {
      throw TangledError.invalidRequest("repository URI must be a sh.tangled.repo AT URI")
    }
  }

  func requireNonempty(_ value: String, name: String) throws {
    guard !value.isEmpty else {
      throw TangledError.invalidRequest("\(name) must not be empty")
    }
  }

  func validateBatch(_ values: [String], name: String) throws {
    guard values.count <= 50 else {
      throw TangledError.invalidRequest("\(name) must contain at most 50 values")
    }
    guard values.allSatisfy({ !$0.isEmpty }) else {
      throw TangledError.invalidRequest("\(name) must not contain an empty value")
    }
  }

  func validateLimit(_ limit: Int?) throws {
    guard let limit else { return }
    guard (1 ... 1000).contains(limit) else {
      throw TangledError.invalidRequest("limit must be between 1 and 1000")
    }
  }
}

struct BobbinRecord<Value: Decodable & Sendable>: Decodable, Sendable {
  let uri: String
  let cid: String?
  let value: Value
}

struct BobbinWireLink: Decodable, Sendable {
  let cid: String

  init(from decoder: any Decoder) throws {
    let singleValue = try decoder.singleValueContainer()
    if let value = try? singleValue.decode(String.self) {
      cid = Self.canonicalCID(value)
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    cid = Self.canonicalCID(try container.decode(String.self, forKey: .cid))
  }

  private static func canonicalCID(_ value: String) -> String {
    if let link = try? LexLink(value) {
      return link.toBaseEncodedString
    }
    guard let data = Data(base64Encoded: value), data.first == 0,
      let link = try? LexLink(Data(data.dropFirst()))
    else {
      return value
    }
    return link.toBaseEncodedString
  }

  private enum CodingKeys: String, CodingKey {
    case cid = "$link"
  }
}
