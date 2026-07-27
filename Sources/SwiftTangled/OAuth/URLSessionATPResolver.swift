import Foundation
import SwiftAtproto
import TangledLexicons

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct URLSessionATPResolver: ATPResolver {
  private let session: URLSession
  private let plcDirectory: URL
  private let handleResolver: URL

  public init(
    session: URLSession = .shared,
    plcDirectory: URL = URL(string: "https://plc.directory")!,
    handleResolver: URL = URL(string: "https://public.api.bsky.app")!
  ) {
    self.session = session
    self.plcDirectory = plcDirectory
    self.handleResolver = handleResolver
  }

  public func resolve(handle: Handle) async throws -> DID? {
    do {
      if let did = try await resolveWellKnown(handle: handle) {
        return did
      }
    } catch {
      if Task.isCancelled { throw CancellationError() }
    }
    return try await resolveWithService(handle: handle)
  }

  private func resolveWellKnown(handle: Handle) async throws -> DID? {
    let url = URL(string: "https://\(handle.rawValue)/.well-known/atproto-did")!
    let request = URLRequest(url: url)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError {
      throw TangledError.network(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw TangledError.serverStatus(-1, "non-HTTP response for handle resolution")
    }
    guard http.statusCode == 200 else {
      throw TangledError.serverStatus(http.statusCode, "handle resolution failed")
    }
    let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return try? DID(string: raw)
  }

  private func resolveWithService(handle: Handle) async throws -> DID? {
    let response: Com.Atproto.IdentityResolveHandle.ResponseBody
    do {
      response = try await HTTPXRPCClient(
        baseURL: handleResolver,
        transport: URLSessionTransport(session: session)
      ).IdentityResolveHandle(handle: .init(handle))
    } catch Com.Atproto.IdentityResolveHandle.Error.handlenotfound {
      return nil
    } catch TangledError.notFound {
      return nil
    }
    guard let did = response.did.typed else {
      throw TangledError.decoding(InvalidResolvedDIDError(value: response.did.rawValue))
    }
    return did
  }

  public func resolve(did: DID) async throws -> DIDDocument? {
    let url = try didDocumentURL(for: did)
    let request = URLRequest(url: url)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError {
      throw TangledError.network(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw TangledError.serverStatus(-1, "non-HTTP response for DID resolution")
    }
    guard http.statusCode == 200 else {
      throw TangledError.serverStatus(http.statusCode, "DID document fetch failed")
    }
    do {
      return try JSONDecoder().decode(DIDDocument.self, from: data)
    } catch {
      throw TangledError.decoding(error)
    }
  }

  private func didDocumentURL(for did: DID) throws -> URL {
    switch did.method {
    case "plc":
      return plcDirectory.appendingPathComponent(did.rawValue)
    case "web":
      let identifier = String(did.rawValue.dropFirst("did:web:".count))
      let host = identifier.replacingOccurrences(of: "%3A", with: ":")
      guard let url = URL(string: "https://\(host)/.well-known/did.json") else {
        throw TangledError.handleNotResolved("invalid did:web target: \(did.rawValue)")
      }
      return url
    default:
      throw TangledError.handleNotResolved("unsupported DID method: \(did.method)")
    }
  }
}

private struct InvalidResolvedDIDError: Error {
  let value: String
}
