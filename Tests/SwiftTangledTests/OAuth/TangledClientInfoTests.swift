import OAuth4Swift
import Testing

@testable import SwiftTangled

@Test func tangledClientInfoDefinesCLIRedirect() {
  let info = OAuth.ClientInfo.tangledCLI
  #expect(
    info.clientId
      == "https://soyokaze-pds-rc-677008170211.asia-northeast1.run.app/tangled/cli-client-metadata.json"
  )
  #expect(info.scopes.first == "atproto")
  #expect(info.scopes.contains("repo:sh.tangled.feed.star"))
  #expect(info.scopes.contains("rpc:sh.tangled.repo.create?aud=*"))
  #expect(info.scopes.contains("identity:handle"))
  #expect(info.scopes.count == Set(info.scopes).count)
  #expect(!info.scopes.contains("transition:generic"))
  #expect(!info.scopes.contains("repo:*"))
  #expect(info.redirectURI.scheme == "http")
  #expect(info.redirectURI.host == "127.0.0.1")
  #expect(info.redirectURI.path == "/callback")
}

@Test func tangledClientInfoWithBoundPortIncludesPort() {
  let info = OAuth.ClientInfo.tangledCLI(boundPort: 54321)
  #expect(info.redirectURI.host == "127.0.0.1")
  #expect(info.redirectURI.port == 54321)
  #expect(info.redirectURI.path == "/callback")
  #expect(info.scopes == OAuth.ClientInfo.tangledCLI.scopes)
}
