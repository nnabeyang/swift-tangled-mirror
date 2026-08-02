import Foundation
import SwiftAtproto
import TangledLexicons

public enum RepositoryReference: Equatable, Hashable, Sendable {
  case atURI(String)
  case repositoryDID(String)
  case ownerAndName(owner: String, name: String)

  public init(_ rawValue: String) throws(TangledError) {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      throw TangledError.invalidRequest("repository reference must not be empty")
    }

    if value.hasPrefix("at://") {
      let uri: ATURI
      do {
        uri = try ATURI(string: value)
      } catch {
        throw TangledError.invalidRequest("invalid repository AT URI: \(value)")
      }
      guard uri.collection?.rawValue == Sh.Tangled.Repo.nsId, uri.rkey != nil,
        uri.fragment == nil
      else {
        throw TangledError.invalidRequest(
          "AT URI must identify a \(Sh.Tangled.Repo.nsId) record"
        )
      }
      self = .atURI(value)
      return
    }

    if value.hasPrefix("did:") && !value.contains("/") {
      do {
        _ = try DID(string: value)
      } catch {
        throw TangledError.invalidRequest("invalid repository DID: \(value)")
      }
      self = .repositoryDID(value)
      return
    }

    let path = Self.remotePath(from: value) ?? value
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    if components.count == 1, components[0].hasPrefix("did:") {
      let did = Self.removingGitSuffix(from: components[0])
      do {
        _ = try DID(string: did)
      } catch {
        throw TangledError.invalidRequest("invalid repository DID: \(did)")
      }
      self = .repositoryDID(did)
      return
    }

    guard components.count == 2 else {
      throw TangledError.invalidRequest(
        "repository must be an AT URI, repo DID, handle/name, or Tangled clone URL"
      )
    }
    let owner = components[0]
    let name = Self.removingGitSuffix(from: components[1])
    guard !name.isEmpty else {
      throw TangledError.invalidRequest("repository name must not be empty")
    }
    do {
      _ = try AtIdentifier(string: owner)
    } catch {
      throw TangledError.invalidRequest("invalid repository owner: \(owner)")
    }
    self = .ownerAndName(owner: owner, name: name)
  }
}

extension RepositoryReference {
  fileprivate static func remotePath(from value: String) -> String? {
    if let url = URL(string: value), let scheme = url.scheme,
      ["http", "https", "ssh", "git"].contains(scheme.lowercased()), url.host != nil
    {
      return decodedPath(url.path)
    }

    guard let atIndex = value.firstIndex(of: "@"),
      let colonIndex = value[atIndex...].firstIndex(of: ":")
    else {
      return nil
    }
    let pathStart = value.index(after: colonIndex)
    guard pathStart < value.endIndex else { return nil }
    return decodedPath(String(value[pathStart...]))
  }

  fileprivate static func decodedPath(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: true)
      .map { String($0).removingPercentEncoding ?? String($0) }
      .joined(separator: "/")
  }

  fileprivate static func removingGitSuffix(from value: String) -> String {
    value.hasSuffix(".git") ? String(value.dropLast(4)) : value
  }
}
