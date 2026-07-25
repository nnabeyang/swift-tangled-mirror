//
//  XRPCRequestComponents.swift
//  _Internal
//
//  Created by Noriaki Watanabe on 2026/05/25.
//

import Foundation
import GermConvenience
import SwiftAtproto

extension XRPCRequestComponents {
  public func constructUrl(serviceUrl: URL) throws -> BundledHTTPRequest {
    var components = try URLComponents(
      url: serviceUrl,
      resolvingAgainstBaseURL: false
    ).tryUnwrap

    components.path = relativePath
    components.percentEncodedQueryItems = queryItems

    return try .init(
      method: method,
      url: components.url.tryUnwrap,
      headerFields: headers,
      body: body
    )
  }
}
