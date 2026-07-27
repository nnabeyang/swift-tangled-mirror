import Foundation

enum RetryAfterHeader {
  static func parse(
    _ value: String?,
    now: () -> Date = Date.init
  ) -> TimeInterval? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.utf8.allSatisfy({ (48 ... 57).contains($0) }) {
      return UInt64(trimmed).map { Double($0) }
    }
    for format in [
      "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'",
      "EEEE',' dd-MMM-yy HH':'mm':'ss 'GMT'",
      "EEE MMM d HH':'mm':'ss yyyy",
    ] {
      let formatter = DateFormatter()
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      formatter.isLenient = false
      if let date = formatter.date(from: trimmed) {
        return max(0, date.timeIntervalSince(now()))
      }
    }
    return nil
  }
}
