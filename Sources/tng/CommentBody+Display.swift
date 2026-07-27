import SwiftTangled

extension CommentBody {
  var displayText: String {
    switch self {
    case .markdown(let value):
      return value.text
    case .unknown(let type, _):
      return "Unsupported comment body (\(type))"
    }
  }
}
