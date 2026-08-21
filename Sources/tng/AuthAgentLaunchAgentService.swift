import Foundation
import Subprocess
import SwiftTangled

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct AuthAgentServiceConfiguration: Equatable, Sendable {
  var sessionFile: String?
  var tmbInstance: String?
  var socketPath: String
  var profile: AuthenticationProfile
  var maximumBodyBytes: UInt64
  var maximumJobUploadBytes: UInt64
}

struct AuthAgentServiceProbe: Equatable, Sendable {
  var accountDID: String
  var handle: String
  var profile: AuthenticationProfile
  var protocolVersion: Int
}

struct AuthAgentServiceStatus: Codable, Equatable, Sendable {
  enum State: String, Codable, Sendable {
    case notInstalled = "not-installed"
    case stopped, running, degraded
  }
  enum SessionState: String, Codable, Sendable {
    case unknown, valid
    case accessTokenExpired = "access-token-expired"
    case missing, invalid
  }
  enum SocketState: String, Codable, Sendable { case unknown, available, unavailable, incompatible }

  var label: String
  var instance: String?
  var state: State
  var pid: Int?
  var socketPath: String?
  var sessionState: SessionState
  var socketState: SocketState
  var accountDID: String?
  var handle: String?
  var profile: String?
  var protocolVersion: Int?
  var authenticationSource: String? = nil
}

enum AuthAgentLaunchAgentServiceError: Error, LocalizedError, Equatable, Sendable {
  case unsupportedPlatform
  case rootUnsupported
  case invalidExecutable
  case invalidInstance
  case invalidConfiguration(String)
  case notInstalled
  case operationFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedPlatform: "auth-agent service management is available only on macOS"
    case .rootUnsupported: "auth-agent service management must run as a non-root user"
    case .invalidExecutable: "service executable must be an absolute executable regular file"
    case .invalidInstance: "service instance must start with a lowercase letter and contain only lowercase letters, digits, or hyphens"
    case .invalidConfiguration(let message): message
    case .notInstalled: "auth-agent LaunchAgent is not installed"
    case .operationFailed(let operation): "LaunchAgent \(operation) failed"
    }
  }
}

struct AuthAgentSystemCommandOutput: Equatable, Sendable {
  var status: Int32
  var stdout: String
  var stderr: String
}

protocol AuthAgentSystemCommandRunning: Sendable {
  func run(executable: String, arguments: [String]) async throws -> AuthAgentSystemCommandOutput
}

struct SubprocessAuthAgentSystemCommandRunner: AuthAgentSystemCommandRunning {
  func run(executable: String, arguments: [String]) async throws -> AuthAgentSystemCommandOutput {
    let result: ExecutionResult<Void, StringOutput<UTF8>, StringOutput<UTF8>>
    do {
      result = try await Subprocess.run(
        CLISubprocess.executable(executable),
        arguments: Arguments(arguments),
        platformOptions: CLISubprocess.platformOptions,
        output: .string(limit: CLISubprocess.textOutputLimit),
        error: .string(limit: CLISubprocess.textOutputLimit)
      )
    } catch { throw AuthAgentLaunchAgentServiceError.operationFailed("command") }
    return AuthAgentSystemCommandOutput(
      status: CLISubprocess.status(result.terminationStatus),
      stdout: result.standardOutput,
      stderr: result.standardError
    )
  }
}

struct AuthAgentLaunchAgentService: Sendable {
  static let baseLabel = "sh.tangled.tng.auth-agent"

  var homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
  var userID: UInt32 = geteuid()
  var commandRunner: any AuthAgentSystemCommandRunning = SubprocessAuthAgentSystemCommandRunner()
  var probe: @Sendable (String) async throws -> AuthAgentServiceProbe = { path in
    let status = try await AuthAgentClient(endpoint: .unix(path: path)).probe()
    return AuthAgentServiceProbe(
      accountDID: status.accountDID,
      handle: status.handle,
      profile: status.profile,
      protocolVersion: AuthAgentProtocol.version
    )
  }

  func install(
    configuration: AuthAgentServiceConfiguration,
    executablePath: String?,
    instance: String?
  ) async throws -> AuthAgentServiceStatus {
    try requireMacOS()
    guard userID != 0 else { throw AuthAgentLaunchAgentServiceError.rootUnsupported }
    let identity = try Self.identity(instance: instance, homeDirectory: homeDirectory)
    let executable = executablePath ?? Bundle.main.executableURL?.path ?? ""
    guard executable.hasPrefix("/"), Self.isExecutableRegularFile(executable) else {
      throw AuthAgentLaunchAgentServiceError.invalidExecutable
    }
    try validate(configuration)
    try Self.ensureDirectory(homeDirectory + "/Library/LaunchAgents", permissions: 0o700)
    try Self.ensureDirectory(identity.logDirectory, permissions: 0o700)
    try writePlist(
      Self.propertyList(
        executable: executable,
        configuration: configuration,
        identity: identity
      ),
      to: identity.plistPath
    )
    _ = try? await launchctl(["bootout", domain + "/" + identity.label])
    try await requireLaunchctl(["bootstrap", domain, identity.plistPath], operation: "install")
    return try await waitForHealthyStatus(instance: instance)
  }

  func start(instance: String?) async throws -> AuthAgentServiceStatus {
    try requireMacOS()
    let identity = try Self.identity(instance: instance, homeDirectory: homeDirectory)
    guard FileManager.default.fileExists(atPath: identity.plistPath) else {
      throw AuthAgentLaunchAgentServiceError.notInstalled
    }
    if try await launchctl(["print", domain + "/" + identity.label]).status != 0 {
      try await requireLaunchctl(["bootstrap", domain, identity.plistPath], operation: "start")
    }
    return try await waitForHealthyStatus(instance: instance)
  }

  func stop(instance: String?) async throws -> AuthAgentServiceStatus {
    try requireMacOS()
    let identity = try Self.identity(instance: instance, homeDirectory: homeDirectory)
    guard FileManager.default.fileExists(atPath: identity.plistPath) else {
      throw AuthAgentLaunchAgentServiceError.notInstalled
    }
    if try await launchctl(["print", domain + "/" + identity.label]).status == 0 {
      try await requireLaunchctl(["bootout", domain + "/" + identity.label], operation: "stop")
    }
    try await waitForDeadSocketAndRemove(configuration(at: identity.plistPath).socketPath)
    return try await waitForHealthyStatus(instance: instance)
  }

  func restart(instance: String?) async throws -> AuthAgentServiceStatus {
    try requireMacOS()
    let identity = try Self.identity(instance: instance, homeDirectory: homeDirectory)
    guard FileManager.default.fileExists(atPath: identity.plistPath) else {
      throw AuthAgentLaunchAgentServiceError.notInstalled
    }
    let target = domain + "/" + identity.label
    if try await launchctl(["print", target]).status == 0 {
      try await requireLaunchctl(["kickstart", "-k", target], operation: "restart")
    } else {
      try await requireLaunchctl(["bootstrap", domain, identity.plistPath], operation: "restart")
    }
    return try await waitForHealthyStatus(instance: instance)
  }

  func uninstall(instance: String?) async throws -> AuthAgentServiceStatus {
    try requireMacOS()
    let identity = try Self.identity(instance: instance, homeDirectory: homeDirectory)
    guard FileManager.default.fileExists(atPath: identity.plistPath) else {
      return Self.emptyStatus(identity: identity, instance: instance)
    }
    let configuration = try configuration(at: identity.plistPath)
    _ = try? await launchctl(["bootout", domain + "/" + identity.label])
    do { try FileManager.default.removeItem(atPath: identity.plistPath) } catch {
      throw AuthAgentLaunchAgentServiceError.operationFailed("uninstall")
    }
    try await waitForDeadSocketAndRemove(configuration.socketPath)
    return Self.emptyStatus(identity: identity, instance: instance)
  }

  func status(instance: String?) async throws -> AuthAgentServiceStatus {
    try requireMacOS()
    let identity: Identity
    do { identity = try Self.identity(instance: instance, homeDirectory: homeDirectory) } catch {
      return AuthAgentServiceStatus(
        label: Self.baseLabel, instance: instance, state: .degraded, pid: nil,
        socketPath: nil, sessionState: .unknown, socketState: .unknown,
        accountDID: nil, handle: nil, profile: nil, protocolVersion: nil
      )
    }
    guard FileManager.default.fileExists(atPath: identity.plistPath) else {
      return Self.emptyStatus(identity: identity, instance: instance)
    }
    let parsedConfiguration: AuthAgentServiceConfiguration
    do { parsedConfiguration = try configuration(at: identity.plistPath) } catch {
      return AuthAgentServiceStatus(
        label: identity.label, instance: instance, state: .degraded, pid: nil,
        socketPath: nil, sessionState: .invalid, socketState: .unknown,
        accountDID: nil, handle: nil, profile: nil, protocolVersion: nil
      )
    }
    let sessionState = Self.sessionState(configuration: parsedConfiguration, homeDirectory: homeDirectory)
    let authenticationSource = parsedConfiguration.tmbInstance == nil ? "native" : "tmb"
    let launchState = try? await launchctl(["print", domain + "/" + identity.label])
    guard let launchState, launchState.status == 0 else {
      return AuthAgentServiceStatus(
        label: identity.label, instance: instance, state: .stopped, pid: nil,
        socketPath: parsedConfiguration.socketPath, sessionState: sessionState,
        socketState: .unavailable, accountDID: nil, handle: nil,
        profile: parsedConfiguration.profile.rawValue, protocolVersion: nil,
        authenticationSource: authenticationSource
      )
    }
    let pid = Self.value(named: "pid", in: launchState.stdout).flatMap(Int.init)
    do {
      let value = try await probe(parsedConfiguration.socketPath)
      return AuthAgentServiceStatus(
        label: identity.label, instance: instance, state: .running, pid: pid,
        socketPath: parsedConfiguration.socketPath, sessionState: sessionState,
        socketState: .available, accountDID: value.accountDID, handle: value.handle,
        profile: value.profile.rawValue, protocolVersion: value.protocolVersion,
        authenticationSource: authenticationSource
      )
    } catch AuthAgentError.incompatibleVersion {
      return AuthAgentServiceStatus(
        label: identity.label, instance: instance, state: .degraded, pid: pid,
        socketPath: parsedConfiguration.socketPath, sessionState: sessionState,
        socketState: .incompatible, accountDID: nil, handle: nil,
        profile: parsedConfiguration.profile.rawValue, protocolVersion: nil,
        authenticationSource: authenticationSource
      )
    } catch {
      return AuthAgentServiceStatus(
        label: identity.label, instance: instance, state: .degraded, pid: pid,
        socketPath: parsedConfiguration.socketPath, sessionState: sessionState,
        socketState: .unavailable, accountDID: nil, handle: nil,
        profile: parsedConfiguration.profile.rawValue, protocolVersion: nil,
        authenticationSource: authenticationSource
      )
    }
  }

  static func propertyList(
    executable: String,
    configuration: AuthAgentServiceConfiguration,
    identity: Identity
  ) -> [String: Any] {
    var arguments = [
      executable, "auth", "agent", "serve",
      "--profile", configuration.profile.rawValue,
      "--socket", configuration.socketPath,
      "--max-body-bytes", String(configuration.maximumBodyBytes),
      "--max-job-upload-bytes", String(configuration.maximumJobUploadBytes),
    ]
    if let tmbInstance = configuration.tmbInstance {
      arguments.append(contentsOf: ["--tmb-instance", tmbInstance])
    }
    var propertyList: [String: Any] = [
      "Label": identity.label,
      "ProgramArguments": arguments,
      "RunAtLoad": true,
      "KeepAlive": ["SuccessfulExit": false],
      "ThrottleInterval": 10,
      "ProcessType": "Background",
      "Umask": "0077",
      "WorkingDirectory": identity.homeDirectory,
      "StandardOutPath": identity.logDirectory + "/stdout.log",
      "StandardErrorPath": identity.logDirectory + "/stderr.log",
    ]
    if let sessionFile = configuration.sessionFile {
      propertyList["EnvironmentVariables"] = ["TNG_SESSION_FILE": sessionFile]
    }
    return propertyList
  }

  static func label(instance: String?) throws -> String {
    try identity(instance: instance, homeDirectory: "/unused").label
  }

  struct Identity: Sendable {
    var label: String
    var homeDirectory: String
    var logDirectory: String
    var plistPath: String
  }

  private var domain: String { "gui/\(userID)" }

  private static func identity(instance: String?, homeDirectory: String) throws -> Identity {
    if let instance,
      instance.range(of: "^[a-z][a-z0-9-]{0,31}$", options: .regularExpression) == nil
    {
      throw AuthAgentLaunchAgentServiceError.invalidInstance
    }
    let suffix = instance.map { ".\($0)" } ?? ""
    let directory = instance ?? "default"
    let label = baseLabel + suffix
    return Identity(
      label: label,
      homeDirectory: homeDirectory,
      logDirectory: homeDirectory + "/Library/Logs/tng/auth-agent/\(directory)",
      plistPath: homeDirectory + "/Library/LaunchAgents/\(label).plist"
    )
  }

  private static func emptyStatus(identity: Identity, instance: String?) -> AuthAgentServiceStatus {
    AuthAgentServiceStatus(
      label: identity.label, instance: instance, state: .notInstalled, pid: nil,
      socketPath: nil, sessionState: .unknown, socketState: .unknown,
      accountDID: nil, handle: nil, profile: nil, protocolVersion: nil
    )
  }

  private func validate(_ configuration: AuthAgentServiceConfiguration) throws {
    guard configuration.socketPath.hasPrefix("/") else {
      throw AuthAgentLaunchAgentServiceError.invalidConfiguration("service paths must be absolute")
    }
    guard configuration.profile == .ciReporting else {
      throw AuthAgentLaunchAgentServiceError.invalidConfiguration("service profile must be ci-reporting")
    }
    guard (configuration.sessionFile == nil) != (configuration.tmbInstance == nil) else {
      throw AuthAgentLaunchAgentServiceError.invalidConfiguration(
        "service must configure exactly one authentication source")
    }
    if let sessionFile = configuration.sessionFile {
      guard sessionFile.hasPrefix("/") else {
        throw AuthAgentLaunchAgentServiceError.invalidConfiguration("service paths must be absolute")
      }
      let store = FileSessionStore(fileURL: URL(fileURLWithPath: sessionFile))
      guard let session = try store.load() else {
        throw AuthAgentLaunchAgentServiceError.invalidConfiguration("ci-reporting session file is missing")
      }
      guard session.profile == .ciReporting else {
        throw AuthAgentLaunchAgentServiceError.invalidConfiguration("session profile must be ci-reporting")
      }
    } else if let tmbInstance = configuration.tmbInstance {
      guard TMBDeviceRegistration.validInstance(tmbInstance) else {
        throw AuthAgentLaunchAgentServiceError.invalidConfiguration("TMB instance is invalid")
      }
      let directory = homeDirectory + "/Library/Application Support/tng/tmb/\(tmbInstance)"
      let device = FileTMBDeviceCredentialStore(
        fileURL: URL(fileURLWithPath: directory + "/device.json"))
      let session = FileTMBSessionStore(
        fileURL: URL(fileURLWithPath: directory + "/session.json"))
      guard try device.load() != nil, try session.load() != nil else {
        throw AuthAgentLaunchAgentServiceError.invalidConfiguration(
          "TMB device and OAuth session state are required")
      }
    }
    let socketParent = URL(fileURLWithPath: configuration.socketPath).deletingLastPathComponent().path
    try Self.ensureDirectory(socketParent, permissions: 0o700)
    var value = stat()
    guard lstat(socketParent, &value) == 0,
      value.st_mode & S_IFMT == S_IFDIR,
      value.st_uid == userID,
      value.st_mode & 0o077 == 0
    else {
      throw AuthAgentLaunchAgentServiceError.invalidConfiguration("socket parent must be owned mode 0700")
    }
  }

  private func configuration(at path: String) throws -> AuthAgentServiceConfiguration {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let value = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard let plist = value as? [String: Any],
      let arguments = plist["ProgramArguments"] as? [String],
      let socket = Self.option("--socket", in: arguments),
      let profileValue = Self.option("--profile", in: arguments),
      let profile = AuthenticationProfile(rawValue: profileValue),
      let body = Self.option("--max-body-bytes", in: arguments).flatMap(UInt64.init),
      let uploads = Self.option("--max-job-upload-bytes", in: arguments).flatMap(UInt64.init)
    else { throw AuthAgentLaunchAgentServiceError.invalidConfiguration("installed service configuration is invalid") }
    let environment = plist["EnvironmentVariables"] as? [String: String]
    let session = environment?["TNG_SESSION_FILE"]
    let tmbInstance = Self.option("--tmb-instance", in: arguments)
    guard (session == nil) != (tmbInstance == nil) else {
      throw AuthAgentLaunchAgentServiceError.invalidConfiguration(
        "installed service authentication source is invalid")
    }
    return AuthAgentServiceConfiguration(
      sessionFile: session, tmbInstance: tmbInstance, socketPath: socket, profile: profile,
      maximumBodyBytes: body, maximumJobUploadBytes: uploads
    )
  }

  private static func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }

  private static func sessionState(
    configuration: AuthAgentServiceConfiguration,
    homeDirectory: String
  ) -> AuthAgentServiceStatus.SessionState {
    do {
      if let path = configuration.sessionFile {
        let store = FileSessionStore(fileURL: URL(fileURLWithPath: path))
        guard let session = try store.load() else { return .missing }
        guard session.profile == .ciReporting else { return .invalid }
        if let expiry = session.archive.tokenState.accessToken.expiry, expiry <= Date() {
          return .accessTokenExpired
        }
      } else if let instance = configuration.tmbInstance {
        let path = homeDirectory + "/Library/Application Support/tng/tmb/\(instance)/session.json"
        guard let session = try FileTMBSessionStore(fileURL: URL(fileURLWithPath: path)).load()
        else { return .missing }
        if session.expiresAt <= Date() { return .accessTokenExpired }
      } else {
        return .invalid
      }
      return .valid
    } catch { return .invalid }
  }

  private func writePlist(_ value: [String: Any], to path: String) throws {
    do {
      let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
      guard chmod(path, 0o600) == 0 else { throw AuthAgentLaunchAgentServiceError.operationFailed("write") }
    } catch let error as AuthAgentLaunchAgentServiceError { throw error } catch { throw AuthAgentLaunchAgentServiceError.operationFailed("write") }
  }

  private func launchctl(_ arguments: [String]) async throws -> AuthAgentSystemCommandOutput {
    try await commandRunner.run(executable: "/bin/launchctl", arguments: arguments)
  }

  private func requireLaunchctl(_ arguments: [String], operation: String) async throws {
    guard try await launchctl(arguments).status == 0 else {
      throw AuthAgentLaunchAgentServiceError.operationFailed(operation)
    }
  }

  private func removeDeadSocketIfPresent(_ path: String) throws {
    var value = stat()
    guard lstat(path, &value) == 0 else {
      if errno == ENOENT { return }
      throw AuthAgentLaunchAgentServiceError.operationFailed("socket inspection")
    }
    guard value.st_mode & S_IFMT == S_IFSOCK, value.st_uid == userID, value.st_nlink == 1 else {
      throw AuthAgentLaunchAgentServiceError.invalidConfiguration("refusing to remove unsafe socket path")
    }
    do {
      _ = try awaitProbeSynchronously(path)
      throw AuthAgentLaunchAgentServiceError.invalidConfiguration("another auth-agent is still listening")
    } catch AuthAgentError.connectionFailed(let code) where code == ECONNREFUSED {
      guard unlink(path) == 0 else { throw AuthAgentLaunchAgentServiceError.operationFailed("socket cleanup") }
    } catch AuthAgentLaunchAgentServiceError.invalidConfiguration {
      throw AuthAgentLaunchAgentServiceError.invalidConfiguration("another auth-agent is still listening")
    } catch {
      throw AuthAgentLaunchAgentServiceError.invalidConfiguration("socket state could not be verified")
    }
  }

  private func waitForDeadSocketAndRemove(_ path: String) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
      do {
        try removeDeadSocketIfPresent(path)
        return
      } catch AuthAgentLaunchAgentServiceError.invalidConfiguration(let message)
        where message == "another auth-agent is still listening" && ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private func waitForHealthyStatus(instance: String?) async throws -> AuthAgentServiceStatus {
    let deadline = ContinuousClock.now + .seconds(5)
    var current = try await status(instance: instance)
    while current.state != .running && ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
      current = try await status(instance: instance)
    }
    return current
  }

  private func awaitProbeSynchronously(_ path: String) throws -> AuthAgentSocketMarker {
    #if os(macOS)
      let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    #else
      let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard descriptor >= 0 else { throw AuthAgentError.connectionFailed(errno) }
    defer { _ = close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw AuthAgentError.invalidSocketPath(path)
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
        for index in bytes.indices { destination[index] = bytes[index] }
      }
    }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw AuthAgentError.connectionFailed(errno) }
    return AuthAgentSocketMarker()
  }

  private struct AuthAgentSocketMarker {}

  private static func isExecutableRegularFile(_ path: String) -> Bool {
    var value = stat()
    return lstat(path, &value) == 0 && value.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
  }

  private static func ensureDirectory(_ path: String, permissions: Int16) throws {
    do {
      try FileManager.default.createDirectory(
        atPath: path, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: permissions)]
      )
      _ = chmod(path, mode_t(permissions))
    } catch { throw AuthAgentLaunchAgentServiceError.operationFailed("directory creation") }
  }

  private static func value(named name: String, in output: String) -> String? {
    output.split(separator: "\n").lazy.compactMap { line -> String? in
      let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      return parts.count == 2 && parts[0] == name ? parts[1] : nil
    }.first
  }

  private func requireMacOS() throws {
    #if !os(macOS)
      throw AuthAgentLaunchAgentServiceError.unsupportedPlatform
    #endif
  }
}
