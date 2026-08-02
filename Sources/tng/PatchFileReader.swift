import Foundation
import SwiftTangled

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct PatchFileReader {
  func read(path: String) throws(TangledError) -> Data {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw TangledError.invalidRequest(
        "unable to open patch file as a regular file: \(path)"
      )
    }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    else {
      close(descriptor)
      throw TangledError.invalidRequest("patch file is not a regular file: \(path)")
    }

    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      let data = try file.readToEnd() ?? Data()
      try file.close()
      return data
    } catch {
      try? file.close()
      throw TangledError.invalidRequest("unable to read patch file: \(path)")
    }
  }
}
