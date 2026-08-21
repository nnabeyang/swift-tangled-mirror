import Subprocess

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

enum CLISubprocess {
  static let textOutputLimit = 8 * 1024 * 1024
  static let patchOutputLimit = 128 * 1024 * 1024

  static var platformOptions: PlatformOptions {
    var options = PlatformOptions()
    // Foundation.Process makes the child a process group leader; Subprocess does not.
    options.processGroupID = 0
    return options
  }

  static func executable(_ path: String) -> Executable {
    .path(FilePath(path))
  }

  static func status(_ terminationStatus: TerminationStatus) -> Int32 {
    switch terminationStatus {
    case .exited(let code): code
    case .signaled(let signal): signal
    }
  }
}
