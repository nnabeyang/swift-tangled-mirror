//
//  AtprotoOAuthAgent.swift
//  AtprotoOAuth
//
//  Created by Mark @ Germ on 2/28/26.
//

import Foundation
import GermConvenience
import Logging
import OAuth4Swift
import SwiftAtproto
import TangledLexicons

import struct HTTPTypes.HTTPFields

public typealias XRPCClientProtocol = XRPCCallable & ATPClientProtocol
public typealias OAuthClientProtocol = XRPCCallable & OAuth.SessionCapabilities

extension OAuth.DPoP.Key {
  static let dummy: Self = .init(alg: .es256, keyData: Data())
}

public actor AtprotoOAuthAgent {
  static let logger = Logger(label: "AtprotoOAuthAgent")

  public nonisolated let authenticatedDID: DID
  public nonisolated var repo: DID { authenticatedDID }
  public nonisolated let resolver: ATPResolver
  public let clientId: String
  public let authFetcher: HTTPFetcher

  weak var delegate: (any OAuthPersistenceDelegate)?

  package enum State {
    case active(OAuth.SessionState)
    case refreshing(
      Task<OAuth.AccessToken, Error>,
      previous: OAuth.SessionState
    )
    case expired

    init(archive: OAuth.SessionState.Archive?) throws {
      if let archive {
        self = .active(
          try .init(
            archive: archive,
            dpopDecoder: OAuth.DPoP.decodeAtproto
          )
        )
      } else {
        self = .expired
      }
    }
  }
  package var state: State
  //we require one, so get the reference to the state in the SessionState at restore (or throw)
  public nonisolated let dpopKey: OAuth.DPoP.Key

  public var lazyServerMetadata: LazyResource<AuthServerMetadata>

  private let saveStream: AsyncStream<OAuth.SessionState.TokenState?>
  private let saveContinuation: AsyncStream<OAuth.SessionState.TokenState?>.Continuation
  public enum StateUpdate: Sendable {
    case loggedOut
  }
  public let updateStream: AsyncStream<StateUpdate>
  private let updateContinuation: AsyncStream<StateUpdate>.Continuation

  private let clientAuth = OAuth.ClientAuth.None()

  private init(
    did: DID,
    clientId: String,
    state: State,
    authFetcher: HTTPFetcher,
    atprotoResolver: ATPResolver,
    delegate: (any OAuthPersistenceDelegate)?
  ) throws {
    self.authenticatedDID = did
    self.clientId = clientId
    self.state = state
    self.authFetcher = authFetcher
    self.resolver = atprotoResolver
    self.delegate = delegate

    self.lazyServerMetadata = .init(
      fetchTaskGenerator: {
        Task {
          let didDoc = try await atprotoResolver.resolve(did: did)
            .tryUnwrap
          return
            try await AtprotoOAuthUtils
            .getAuthorizationServerURL(
              pdsServiceEndpoint: try didDoc.pdsUrl,
              authFetcher: authFetcher
            ).0
        }
      })
    switch state {
    case .active(let sessionState):
      let dpopState = try sessionState.dPoPState.tryUnwrap
      dpopState.nonceCache.countLimit = 25
      self.dpopKey = dpopState.signingKey
    default:
      self.dpopKey = .dummy
    }

    (
      saveStream,
      saveContinuation
    ) = AsyncStream<OAuth.SessionState.TokenState?>
      .makeStream(bufferingPolicy: .bufferingNewest(1))

    (updateStream, updateContinuation) = AsyncStream<StateUpdate>
      .makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  public init(
    did: DID,
    clientId: String,
    authFetcher: HTTPFetcher,
    atprotoResolver: ATPResolver
  ) {
    self.authenticatedDID = did
    self.clientId = clientId
    self.state = .expired
    self.dpopKey = .dummy
    self.authFetcher = authFetcher
    self.resolver = atprotoResolver
    self.delegate = nil

    self.lazyServerMetadata = .init(
      fetchTaskGenerator: {
        Task {
          let didDoc = try await atprotoResolver.resolve(did: did)
            .tryUnwrap
          return
            try await AtprotoOAuthUtils
            .getAuthorizationServerURL(
              pdsServiceEndpoint: try didDoc.pdsUrl,
              authFetcher: authFetcher
            ).0
        }
      })

    (
      saveStream,
      saveContinuation
    ) = AsyncStream<OAuth.SessionState.TokenState?>
      .makeStream(bufferingPolicy: .bufferingNewest(1))

    (updateStream, updateContinuation) = AsyncStream<StateUpdate>
      .makeStream(bufferingPolicy: .bufferingNewest(1))

  }

  var sessionState: OAuth.SessionState? {
    switch state {
    case .active(let sessionState):
      sessionState
    case .refreshing(_, previous: let sessionState):
      sessionState
    case .expired:
      nil
    }
  }
}

extension AtprotoOAuthAgent {
  public struct Archive: Sendable, Codable {
    let did: String
    public var session: OAuth.SessionState.Archive?

    public init(did: String, session: OAuth.SessionState.Archive?) {
      self.did = did
      self.session = session
    }
  }

  package static func restore(
    archive: Archive,
    clientId: String,
    authFetcher: HTTPFetcher,
    atprotoResolver: ATPResolver,
    delegate: (any OAuthPersistenceDelegate)?
  ) throws -> (
    AtprotoOAuthAgent,
    AsyncStream<OAuth.SessionState.TokenState?>
  ) {
    let session = try AtprotoOAuthAgent(
      archive: archive,
      clientId: clientId,
      authFetcher: authFetcher,
      atprotoResolver: atprotoResolver,
      delegate: delegate
    )
    return (session, session.saveStream)
  }

  public init(
    archive: Archive,
    clientId: String,
    authFetcher: HTTPFetcher,
    atprotoResolver: ATPResolver,
    delegate: (any OAuthPersistenceDelegate)?
  ) throws {
    try self.init(
      did: .init(string: archive.did),
      clientId: clientId,
      state: .init(archive: archive.session),
      authFetcher: authFetcher,
      atprotoResolver: atprotoResolver,
      delegate: delegate
    )
  }
}

extension AtprotoOAuthAgent: OAuthClientProtocol {
  public nonisolated var did: DID {
    repo
  }

  nonisolated public func getProxy(nsid: String) -> String? {
    nil
  }

  public func response(
    _ requestComponents: SwiftAtproto.XRPCRequestComponents
  ) async throws -> Data {
    let pdsUrl = try await getPDSUrl()

    let request = try requestComponents.constructUrl(serviceUrl: pdsUrl)

    do {
      return try Self.checked(try await authResponse(for: request)).data
    } catch OAuth.Errors.httpResponse(let response) {
      throw Self.failure(response)
    }
  }

  // authResponse throws httpResponse without decoding the body, and returns a
  // 401 that survived the refresh unchecked.
  private static func checked(_ response: HTTPDataResponse) throws -> HTTPDataResponse {
    guard response.response.status.kind != .successful else {
      return response
    }
    throw failure(response)
  }

  private static func failure(_ response: HTTPDataResponse) -> OAuth.Errors {
    guard
      let errorResponse = try? JSONDecoder().decode(
        OAuth.ErrorResponse.self,
        from: response.data
      )
    else {
      return .httpResponse(response: response)
    }
    return .oauthError(errorResponse, response.response.status)
  }

  public var authServerMetadata: AuthServerMetadata {
    get async throws {
      try await lazyServerMetadata.lazyValue(isolation: self)
    }
  }

  public var authToken: OAuth.AccessToken {
    get async throws {
      switch state {
      case .active(let sessionState):
        return sessionState.tokenState.accessToken
      case .refreshing(let refreshTask, previous: _):
        return try await refreshTask.value
      case .expired:
        throw OAuthSessionError.sessionInactive
      }
    }
  }

  public func startRefresh(
    continueCondition: (OAuth.RefreshToken?) -> Bool,
    refreshClosure:
      @escaping @concurrent (
        OAuth.SessionState.Snapshot,
        OAuth.RefreshToken
      ) async throws -> OAuth.SessionState.TokenState?
  ) -> Task<OAuth.AccessToken, Error>? {
    switch state {
    case .refreshing(let task, previous: _):
      return task
    case .expired:
      return nil
    case .active(let sessionState):
      guard let refreshToken = sessionState.tokenState.refreshToken else {
        //can't refresh without a refresh token
        return nil
      }
      guard continueCondition(refreshToken) else {
        Self.logger.notice("Skipping refresh")
        return nil
      }
      //get sendable objects from the mutable sessionState
      let snapshot = sessionState.snapshot

      let newTask = Task {
        let newTokenState: OAuth.SessionState.TokenState?
        do {
          newTokenState = try await refreshClosure(
            snapshot,
            refreshToken
          )
        } catch {
          //return to previous. If auth was actually unauthorized
          //oauth4swift would return nil to signal we terminate the session
          //guard against actor reentrancy: only restore if we're still refreshing
          if case .refreshing = state {
            state = .active(sessionState)
          }
          Self.logger.notice(
            "refresh failed with error \(error), restoring previous state"
          )
          return sessionState.tokenState.accessToken
        }

        saveContinuation.yield(newTokenState)
        delegate?.save(newTokenState)

        if let newTokenState {
          sessionState.updated(tokenState: newTokenState)
          //guard against actor reentrancy: only activate if we're still refreshing
          if case .refreshing = state {
            state = .active(sessionState)
          }

          return sessionState.tokenState.accessToken
        } else {
          //guard against actor reentrancy: only expire if we're still refreshing
          if case .refreshing = state {
            state = .expired
            updateContinuation.yield(.loggedOut)
          }
          throw OAuthSessionError.sessionInactive
        }
      }

      state = .refreshing(newTask, previous: sessionState)

      return newTask
    }
  }

  public var tokenRefreshOptions: OAuth.TokenRefreshOptions {
    TokenRefreshOptions(did: did)
  }
}

extension AtprotoOAuthAgent: OAuth.DPoP.Signing {

  public func getNonce(origin: String) -> OAuth.DPoP.IndexedNonce? {
    sessionState?.dPoPState?.getNonce(origin: origin)
  }

  public func cacheNonce(
    response: HTTPDataResponse,
    requestUrl: URL
  ) throws {
    try sessionState?.dPoPState?
      .cacheNonce(response: response, requestUrl: requestUrl)
  }

}

extension AtprotoOAuthAgent {
  func getPDSUrl() async throws -> URL {
    try await self.resolver.resolve(did: repo).tryUnwrap.pdsUrl
  }
}

extension AtprotoOAuthAgent: OAuth.ClientAuth.Authenticable {
  public nonisolated var tokenEndpointAuthMethod: OAuth.ClientAuth.TokenEndpointMethods {
    .none
  }

  public func authenticate(inputs: OAuth.ClientAuth.Inputs) async throws -> (
    FormParameters,
    HTTPFields
  ) {
    try await clientAuth.authenticate(clientId: clientId, inputs: inputs)
  }
}
