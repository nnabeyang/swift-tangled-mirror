import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

final class AuthAgentSocket: @unchecked Sendable {
  let fileDescriptor: Int32
  private let maximumBodyBytes: UInt64

  init(fileDescriptor: Int32, maximumBodyBytes: UInt64) {
    self.fileDescriptor = fileDescriptor
    self.maximumBodyBytes = maximumBodyBytes
    #if canImport(Darwin)
      var enabled: Int32 = 1
      _ = withUnsafePointer(to: &enabled) {
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
      }
    #endif
  }

  deinit {
    authAgentClose(fileDescriptor)
  }

  static func connectUnix(path: String, maximumBodyBytes: UInt64) throws -> AuthAgentSocket {
    guard path.hasPrefix("/"), path.utf8.count < unixPathCapacity else {
      throw AuthAgentError.invalidSocketPath(path)
    }
    let descriptor = socket(AF_UNIX, streamSocketType, 0)
    guard descriptor >= 0 else { throw AuthAgentError.connectionFailed(errno) }
    var address = sockaddr_un()
    #if canImport(Darwin)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    address.sun_family = sa_family_t(AF_UNIX)
    copyUnixPath(path, to: &address)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        authAgentConnect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let code = errno
      authAgentClose(descriptor)
      throw AuthAgentError.connectionFailed(code)
    }
    return AuthAgentSocket(fileDescriptor: descriptor, maximumBodyBytes: maximumBodyBytes)
  }

  #if canImport(Darwin)
    static func connectVSock(port: UInt32, maximumBodyBytes: UInt64) throws -> AuthAgentSocket {
      let descriptor = socket(AF_VSOCK, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw AuthAgentError.connectionFailed(errno) }
      var address = sockaddr_vm()
      address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
      address.svm_family = sa_family_t(AF_VSOCK)
      address.svm_port = port
      address.svm_cid = UInt32(VMADDR_CID_HOST)
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
        }
      }
      guard result == 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw AuthAgentError.connectionFailed(code)
      }
      return AuthAgentSocket(fileDescriptor: descriptor, maximumBodyBytes: maximumBodyBytes)
    }
  #endif

  func send(_ frame: AuthAgentFrame) throws {
    guard frame.metadata.bodyLength <= maximumBodyBytes else {
      throw AuthAgentError.bodyTooLarge(
        maximumBytes: maximumBodyBytes,
        actualBytes: frame.metadata.bodyLength
      )
    }
    try writeAll(AuthAgentProtocolCodec.encode(frame))
  }

  func receive() throws -> AuthAgentFrame {
    let header = try readExactly(4)
    let metadataLength = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard metadataLength <= AuthAgentProtocol.maximumMetadataBytes else {
      throw AuthAgentError.metadataTooLarge
    }
    let metadata = try AuthAgentProtocolCodec.decodeMetadata(
      try readExactly(Int(metadataLength))
    )
    guard metadata.bodyLength <= maximumBodyBytes else {
      throw AuthAgentError.bodyTooLarge(
        maximumBytes: maximumBodyBytes,
        actualBytes: metadata.bodyLength
      )
    }
    guard metadata.bodyLength <= UInt64(Int.max) else {
      throw AuthAgentError.bodyTooLarge(maximumBytes: UInt64(Int.max), actualBytes: metadata.bodyLength)
    }
    return AuthAgentFrame(
      metadata: metadata,
      body: try readExactly(Int(metadata.bodyLength))
    )
  }

  private func readExactly(_ count: Int) throws -> Data {
    if count == 0 { return Data() }
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let readCount = data.withUnsafeMutableBytes { bytes in
        authAgentRead(fileDescriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
      }
      if readCount == 0 { throw AuthAgentError.connectionClosed }
      if readCount < 0 {
        if errno == EINTR { continue }
        throw AuthAgentError.ioFailed(errno)
      }
      offset += readCount
    }
    return data
  }

  private func writeAll(_ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { bytes in
        authAgentWrite(fileDescriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if written < 0 {
        if errno == EINTR { continue }
        throw AuthAgentError.ioFailed(errno)
      }
      if written == 0 { throw AuthAgentError.connectionClosed }
      offset += written
    }
  }
}

func makeUnixListener(path: String) throws -> Int32 {
  guard path.hasPrefix("/"), path.utf8.count < unixPathCapacity else {
    throw AuthAgentError.invalidSocketPath(path)
  }
  let descriptor = socket(AF_UNIX, streamSocketType, 0)
  guard descriptor >= 0 else { throw AuthAgentError.connectionFailed(errno) }
  var address = sockaddr_un()
  #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  #endif
  address.sun_family = sa_family_t(AF_UNIX)
  copyUnixPath(path, to: &address)
  let result = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      authAgentBind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard result == 0, listen(descriptor, 16) == 0 else {
    let code = errno
    authAgentClose(descriptor)
    throw AuthAgentError.connectionFailed(code)
  }
  return descriptor
}

private let unixPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

#if canImport(Darwin)
  private let streamSocketType = SOCK_STREAM
#else
  private let streamSocketType = Int32(SOCK_STREAM.rawValue)
#endif

private func copyUnixPath(_ path: String, to address: inout sockaddr_un) {
  let bytes = Array(path.utf8) + [0]
  withUnsafeMutablePointer(to: &address.sun_path) { pointer in
    pointer.withMemoryRebound(to: UInt8.self, capacity: unixPathCapacity) { destination in
      destination.initialize(repeating: 0, count: unixPathCapacity)
      bytes.withUnsafeBytes { source in
        destination.update(
          from: source.bindMemory(to: UInt8.self).baseAddress!,
          count: bytes.count
        )
      }
    }
  }
}

#if canImport(Darwin)
  func authAgentAccept(_ fd: Int32) -> Int32 { Darwin.accept(fd, nil, nil) }
  func authAgentBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    Darwin.bind(fd, address, length)
  }
  func authAgentClose(_ fd: Int32) { _ = Darwin.close(fd) }
  func authAgentConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    Darwin.connect(fd, address, length)
  }
  func authAgentRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    Darwin.read(fd, buffer, count)
  }
  func authAgentWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Darwin.write(fd, buffer, count)
  }
#elseif canImport(Glibc)
  func authAgentAccept(_ fd: Int32) -> Int32 { Glibc.accept(fd, nil, nil) }
  func authAgentBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    Glibc.bind(fd, address, length)
  }
  func authAgentClose(_ fd: Int32) { _ = Glibc.close(fd) }
  func authAgentConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    Glibc.connect(fd, address, length)
  }
  func authAgentRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    Glibc.read(fd, buffer, count)
  }
  func authAgentWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Glibc.write(fd, buffer, count)
  }
#endif
