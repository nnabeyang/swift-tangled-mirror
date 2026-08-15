import Foundation
import SwiftAtproto
import TangledLexicons
import Testing

@testable import SwiftTangled

@Suite struct AuthAgentProtocolTests {
  @Test func frameRoundTripPreservesRawBodyAndMetadata() throws {
    let body = Data([0, 1, 2, 255])
    var metadata = AuthAgentFrameMetadata(
      kind: .xrpc,
      requestID: "request-1",
      bodyLength: UInt64(body.count)
    )
    metadata.method = "POST"
    metadata.nsid = "com.atproto.repo.uploadBlob"
    metadata.headers = ["content-type": "application/octet-stream"]
    let encoded = try AuthAgentProtocolCodec.encode(
      AuthAgentFrame(metadata: metadata, body: body)
    )

    let length = encoded.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    let decodedMetadata = try AuthAgentProtocolCodec.decodeMetadata(
      encoded.subdata(in: 4 ..< (4 + Int(length)))
    )
    let decodedBody = encoded.suffix(from: 4 + Int(length))

    #expect(decodedMetadata == metadata)
    #expect(decodedBody == body)
  }

  @Test func codecRejectsMismatchedBodyLengthAndUnknownVersion() {
    #expect(throws: AuthAgentError.self) {
      _ = try AuthAgentProtocolCodec.encode(
        AuthAgentFrame(
          metadata: .init(kind: .xrpc, bodyLength: 2),
          body: Data([1])
        )
      )
    }

    var metadata = AuthAgentFrameMetadata(kind: .status)
    metadata.version = 999
    #expect(throws: AuthAgentError.self) {
      _ = try AuthAgentProtocolCodec.encode(AuthAgentFrame(metadata: metadata))
    }
  }

  @Test func endpointAcceptsOnlyHostVSockURLs() throws {
    #expect(
      try AuthAgentEndpoint(environmentValue: "vsock://host:10241")
        == .vsock(port: 10_241)
    )
    for invalid in [
      "unix:///tmp/agent.sock",
      "vsock://guest:10241",
      "vsock://host:0",
      "https://host:10241",
    ] {
      #expect(throws: AuthAgentError.self) {
        _ = try AuthAgentEndpoint(environmentValue: invalid)
      }
    }
  }

  @Test func protocolLimitsKeepArtifactAndBrokerQuotasSeparate() {
    #expect(AuthAgentProtocol.artifactMaximumBytes == 50 * 1024 * 1024)
    #expect(AuthAgentProtocol.defaultMaximumBodyBytes == 128 * 1024 * 1024)
    #expect(AuthAgentProtocol.defaultMaximumJobUploadBytes == 512 * 1024 * 1024)
  }

  @Test func policyDecodesQueryValuesAndRejectsDuplicates() throws {
    #expect(
      try authAgentQueryValues([
        .init(name: "repo", value: "did%3Aplc%3Atestalice"),
        .init(name: "collection", value: "sh.tangled.repo.artifact"),
      ]) == [
        "repo": "did:plc:testalice",
        "collection": "sh.tangled.repo.artifact",
      ])
    #expect(throws: AuthAgentError.self) {
      _ = try authAgentQueryValues([
        .init(name: "repo", value: "did%3Aplc%3Atestalice"),
        .init(name: "repo", value: "did%3Aplc%3Aother"),
      ])
    }
  }

  @Test func clientNormalizesPercentEncodedQueryValuesForTheWireProtocol() throws {
    #expect(
      try authAgentWireQueryItem(
        URLQueryItem(name: "repo", value: "did%3Aplc%3Atestalice")
      ) == AuthAgentQueryItem(name: "repo", value: "did:plc:testalice")
    )
    #expect(
      try authAgentWireQueryItem(
        URLQueryItem(name: "collection", value: "sh.tangled.repo.artifact")
      ) == AuthAgentQueryItem(name: "collection", value: "sh.tangled.repo.artifact")
    )
  }

  @Test func serverProbeReturnsRestrictedStatusOverAProtectedUnixSocket() async throws {
    let fixture = try await makeServerFixture()
    let socketPath = fixture.socketPath
    let task = fixture.task
    defer { task.cancel() }

    for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: socketPath) {
      try await Task.sleep(for: .milliseconds(10))
    }
    let status = try await AuthAgentClient(endpoint: .unix(path: socketPath)).probe()
    #expect(status.accountDID == "did:plc:testalice")
    #expect(status.profile == .ciReporting)
    #expect(status.repositoryDID == nil)
    #expect(status.operations == AuthAgentOperation.allCases)
    #expect(status.maximumBodyBytes == AuthAgentProtocol.defaultMaximumBodyBytes)

    let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
  }

  @Test func boundServerRejectsAnXRPCOutsideTheOperationAllowlist() async throws {
    let fixture = try await makeServerFixture()
    defer { fixture.task.cancel() }
    let socket = try AuthAgentSocket.connectUnix(
      path: fixture.socketPath,
      maximumBodyBytes: AuthAgentProtocol.defaultMaximumBodyBytes
    )
    var bind = AuthAgentFrameMetadata(kind: .bind, requestID: "bind")
    bind.jobID = "job-1"
    bind.repositoryDID = "did:plc:repository"
    bind.operations = [.artifactUpload]
    bind.deadlineUnixMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
    try socket.send(AuthAgentFrame(metadata: bind))
    #expect(try socket.receive().metadata.kind == .response)

    let body = Data(#"{"repo":"did:plc:testalice","collection":"sh.tangled.actor.profile","record":{}}"#.utf8)
    var request = AuthAgentFrameMetadata(
      kind: .xrpc,
      requestID: "denied",
      bodyLength: UInt64(body.count)
    )
    request.method = "POST"
    request.nsid = "com.atproto.repo.putRecord"
    try socket.send(AuthAgentFrame(metadata: request, body: body))
    let failure = try socket.receive().metadata
    #expect(failure.kind == .failure)
    #expect(failure.requestID == "denied")
    #expect(failure.errorCode == "policy_denied")
  }

  @Test func serverUsesInjectedTMBSessionClientForAllowedXRPC() async throws {
    let upstream = RecordingAuthAgentUpstream()
    let fixture = try await makeServerFixture(client: upstream)
    defer { fixture.task.cancel() }
    let socket = try AuthAgentSocket.connectUnix(
      path: fixture.socketPath,
      maximumBodyBytes: AuthAgentProtocol.defaultMaximumBodyBytes
    )
    var bind = AuthAgentFrameMetadata(kind: .bind, requestID: "bind")
    bind.jobID = "job-1"
    bind.repositoryDID = "did:plc:repository"
    bind.operations = [.artifactUpload]
    bind.deadlineUnixMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
    try socket.send(AuthAgentFrame(metadata: bind))
    #expect(try socket.receive().metadata.kind == .response)

    var request = AuthAgentFrameMetadata(kind: .xrpc, requestID: "allowed")
    request.method = "GET"
    request.nsid = "com.atproto.repo.listRecords"
    request.query = [
      .init(name: "repo", value: "did:plc:testalice"),
      .init(name: "collection", value: "sh.tangled.repo.artifact"),
    ]
    try socket.send(AuthAgentFrame(metadata: request))
    let response = try socket.receive()
    #expect(response.metadata.kind == .response)
    #expect(response.metadata.statusCode == 200)
    #expect(response.body == Data(#"{"records":[]}"#.utf8))
    #expect(await upstream.requestCount() == 1)
  }

  private func makeServerFixture() async throws -> (
    socketPath: String,
    task: Task<Void, Error>
  ) {
    let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent(
      "tng-agent-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let socketPath = directory.appendingPathComponent("agent.sock").path
    let store = InMemorySessionStore()
    store.write(
      try SessionStoreTestHelpers.makeStoredSession(
        profile: .ciReporting,
        clientID: "https://soyokaze-pds-rc-677008170211.asia-northeast1.run.app/tangled/cli-client-metadata.json",
        scopes: tangledCIReportingScopes,
        includeDPoPKey: true
      )
    )
    let server = try AuthAgentServer(
      configuration: .init(socketPath: socketPath, profile: .ciReporting),
      sessionStore: store
    )
    let task = Task {
      defer { try? FileManager.default.removeItem(at: directory) }
      try await server.serve()
    }
    for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: socketPath) {
      try await Task.sleep(for: .milliseconds(10))
    }
    return (socketPath, task)
  }

  private func makeServerFixture(client: any XRPCCallable) async throws -> (
    socketPath: String,
    task: Task<Void, Error>
  ) {
    let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent(
      "tng-agent-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let socketPath = directory.appendingPathComponent("agent.sock").path
    let server = try AuthAgentServer(
      configuration: .init(socketPath: socketPath, profile: .ciReporting),
      authentication: AuthAgentAuthentication(
        accountDID: "did:plc:testalice",
        handle: "alice.example",
        profile: .ciReporting,
        authorizedScopes: ["atproto", "transition:generic"],
        client: client
      )
    )
    let task = Task {
      defer { try? FileManager.default.removeItem(at: directory) }
      try await server.serve()
    }
    for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: socketPath) {
      try await Task.sleep(for: .milliseconds(10))
    }
    return (socketPath, task)
  }
}

private actor RecordingAuthAgentUpstream: XRPCCallable {
  private var requests: [XRPCRequestComponents] = []

  nonisolated func getProxy(nsid _: String) -> String? { nil }

  func response(_ components: XRPCRequestComponents) async throws -> Data {
    requests.append(components)
    return Data(#"{"records":[]}"#.utf8)
  }

  func requestCount() -> Int { requests.count }
}
