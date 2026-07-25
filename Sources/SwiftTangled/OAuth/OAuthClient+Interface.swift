//
//  OAuthClient+Interface.swift
//  AtprotoOAuth
//
//  Created by Mark @ Germ on 2/17/26.
//

import Crypto
import Foundation
import GermConvenience
import OAuth4Swift
import SwiftAtproto

//Germ will always do pre-processing so we will know did,
//but you can start from handle
public enum AuthIdentity: Sendable {
  case handle(Handle)
  //optionally pass in handle to fill into the UI of the web auth sheet
  case did(DID, handle: Handle?)

  var serverHint: String {
    switch self {
    case .handle(let handle):
      handle.rawValue
    case .did(let did, let handle):
      //Bluesky server shows did if we pass a did, so we favor
      //the user-facing handle
      //https://github.com/bluesky-social/atproto/issues/4900
      handle?.rawValue ?? did.rawValue
    }
  }
}
