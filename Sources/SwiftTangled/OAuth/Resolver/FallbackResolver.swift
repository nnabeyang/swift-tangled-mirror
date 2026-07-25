//
//  FallbackResolver.swift
//  AtprotoGerm
//
//  Created by Anna Mistele on 4/8/26.
//

import GermConvenience
import SwiftAtproto

public struct FallbackResolver: ATPResolver {
  let defaultResolver: ATPResolver
  let fallbackResolver: ATPResolver

  public init(
    defaultResolver: ATPResolver,
    fallbackResolver: ATPResolver
  ) {
    self.defaultResolver = defaultResolver
    self.fallbackResolver = fallbackResolver
  }

  public func resolve(handle: Handle) async throws
    -> DID?
  {
    do {
      return try await defaultResolver.resolve(handle: handle)
    } catch {
      return try await fallbackResolver.resolve(handle: handle)
    }
  }

  public func resolve(did: DID) async throws
    -> DIDDocument?
  {
    do {
      return try await defaultResolver.resolve(did: did)
    } catch {
      return try await fallbackResolver.resolve(did: did)
    }
  }

  public func verifiedResolve(
    handle: Handle
  ) async throws -> (DIDDocument.Verified)? {
    do {
      return try await defaultResolver.verifiedResolve(handle: handle)
    } catch {
      return try await fallbackResolver.verifiedResolve(handle: handle)
    }
  }
}
