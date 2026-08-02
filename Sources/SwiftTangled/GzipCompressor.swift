import CZlib
import Foundation

enum GzipCompressor {
  static func compress(_ data: Data) throws(TangledError) -> Data {
    guard !data.isEmpty else {
      throw TangledError.invalidRequest("pull request patch must not be empty")
    }

    let input = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
    defer { input.deallocate() }
    data.copyBytes(to: input, count: data.count)

    let capacity = Int(compressBound(uLong(data.count))) + 32
    let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    defer { output.deallocate() }

    var stream = z_stream()
    stream.next_in = input
    stream.avail_in = uInt(data.count)
    stream.next_out = output
    stream.avail_out = uInt(capacity)

    guard
      deflateInit2_(
        &stream,
        Z_DEFAULT_COMPRESSION,
        Z_DEFLATED,
        15 + 16,
        8,
        Z_DEFAULT_STRATEGY,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
      ) == Z_OK
    else {
      throw TangledError.transport("failed to initialize gzip compression")
    }
    defer { deflateEnd(&stream) }

    guard deflate(&stream, Z_FINISH) == Z_STREAM_END else {
      throw TangledError.transport("failed to gzip pull request patch")
    }
    return Data(bytes: output, count: capacity - Int(stream.avail_out))
  }
}
