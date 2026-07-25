import Foundation
import SwiftAtproto

enum ArtifactValidation {
  static func name(_ rawValue: String) throws -> String {
    guard !rawValue.isEmpty,
      rawValue != ".",
      rawValue != "..",
      !rawValue.contains("/"),
      !rawValue.contains("\\"),
      !rawValue.unicodeScalars.contains(where: {
        $0.value == 0 || CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw ArtifactError.invalidName(rawValue)
    }
    return rawValue
  }

  static func tagData(_ hash: String) throws -> Data {
    guard hash.count == 40 else {
      throw TangledError.invalidRequest("tag object hash must contain 40 hexadecimal characters")
    }
    var data = Data()
    data.reserveCapacity(20)
    var index = hash.startIndex
    for _ in 0 ..< 20 {
      let next = hash.index(index, offsetBy: 2)
      guard let byte = UInt8(hash[index ..< next], radix: 16) else {
        throw TangledError.invalidRequest(
          "tag object hash must contain 40 hexadecimal characters"
        )
      }
      data.append(byte)
      index = next
    }
    return data
  }

  static func recordOwner(_ uriValue: String, collection: String) throws -> DID {
    guard let uri = FormatString<ATURI>(rawValue: uriValue).typed,
      uri.collection?.rawValue == collection,
      uri.rkey != nil,
      case .did(let did) = uri.authority
    else {
      throw TangledError.decoding(ArtifactSupportError.invalidRecordURI(uriValue))
    }
    return did
  }
}

private enum ArtifactSupportError: Error, Sendable {
  case invalidRecordURI(String)
}
