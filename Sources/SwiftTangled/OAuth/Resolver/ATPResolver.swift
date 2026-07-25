//
//  ATPResolver.swift
//  AtprotoOAuth
//
//  Created by Noriaki Watanabe on 2026/07/03.
//

import Foundation
import GermConvenience
import SwiftAtproto

public protocol ATPResolver: DIDHandleResolver, Sendable {
  /// Like com.atproto.identity.resolveHandle, or compatible resolver services.
  func resolve(handle: Handle) async throws -> DID?

  /// Equivalent to a PLC query or did:web lookup.
  func resolve(did: DID) async throws -> DIDDocument?

  func verifiedResolve(
    handle: Handle
  ) async throws -> DIDDocument.Verified?
}

extension ATPResolver {
  public func resolveDID(handle: Handle) async throws -> DID {
    try await resolve(handle: handle).tryUnwrap
  }

  public func verifiedResolve(
    handle: Handle
  ) async throws -> DIDDocument.Verified? {
    guard let did = try await resolve(handle: handle) else {
      return nil
    }

    return try await resolve(did: did).tryUnwrap
      .verified(expecting: handle, did: did)
  }

  public func verifiedResolve(
    atIdentifier: AtIdentifier
  ) async throws -> DIDDocument.Verified? {
    switch atIdentifier {
    case .handle(let handle):
      try await verifiedResolve(handle: handle)
    case .did(let did):
      try await resolve(did: did)?.verified(resolver: self)
    }
  }
}
