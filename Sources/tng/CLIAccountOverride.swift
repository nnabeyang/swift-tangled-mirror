import ArgumentParser
import Synchronization

enum CLIAccountOverride {
  private static let storage = Mutex<String?>(nil)

  static var identifier: String? {
    storage.withLock { $0 }
  }

  static func set(_ identifier: String?) {
    storage.withLock { $0 = identifier }
  }

  static func extract(from arguments: [String]) throws -> (arguments: [String], account: String?) {
    var filtered: [String] = []
    var account: String?
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--" {
        filtered.append(contentsOf: arguments[index...])
        break
      }
      let value: String?
      if argument == "--account" {
        index += 1
        guard index < arguments.count else {
          throw ValidationError("Missing value for '--account <account>'")
        }
        value = arguments[index]
      } else if argument.hasPrefix("--account=") {
        value = String(argument.dropFirst("--account=".count))
      } else {
        value = nil
      }

      if let value {
        guard account == nil else { throw ValidationError("--account may only be specified once") }
        guard !value.isEmpty else { throw ValidationError("--account must not be empty") }
        account = value
      } else {
        filtered.append(argument)
      }
      index += 1
    }
    return (filtered, account)
  }
}
