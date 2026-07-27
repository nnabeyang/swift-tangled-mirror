import Foundation
import Testing

@testable import SwiftTangled

@Suite struct RetryAfterHeaderTests {
  @Test func parsesIntegerDeltaSeconds() {
    #expect(RetryAfterHeader.parse("120") == 120)
    #expect(RetryAfterHeader.parse("0") == 0)
    #expect(RetryAfterHeader.parse("  15  ") == 15)
    #expect(RetryAfterHeader.parse("2.5") == nil)
  }

  @Test func rejectsNegativeDeltaSeconds() {
    #expect(RetryAfterHeader.parse("-10") == nil)
  }

  @Test func parsesObsoleteHTTPDateForms() throws {
    let now = try #require(
      ISO8601DateFormatter().date(from: "2026-10-21T07:27:00Z")
    )

    #expect(RetryAfterHeader.parse("Wednesday, 21-Oct-26 07:28:00 GMT") { now } == 60)
    #expect(RetryAfterHeader.parse("Wed Oct 21 07:28:00 2026") { now } == 60)
  }

  @Test func parsesPreferredHTTPDateFormat() {
    var components = DateComponents()
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = 2026
    components.month = 10
    components.day = 21
    components.hour = 7
    components.minute = 26
    components.second = 0
    let now = Calendar(identifier: .gregorian).date(from: components)!

    let interval = RetryAfterHeader.parse("Wed, 21 Oct 2026 07:28:00 GMT") { now }
    #expect(interval == 120)
  }

  @Test func returnsZeroForHTTPDateInThePast() {
    var components = DateComponents()
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = 2026
    components.month = 10
    components.day = 21
    components.hour = 7
    components.minute = 28
    components.second = 0
    let now = Calendar(identifier: .gregorian).date(from: components)!

    let sameMoment = RetryAfterHeader.parse("Wed, 21 Oct 2026 07:28:00 GMT") { now }
    let earlier = RetryAfterHeader.parse("Wed, 21 Oct 2026 05:28:00 GMT") { now }

    #expect(sameMoment == 0)
    #expect(earlier == 0)
  }

  @Test func returnsNilForMissingOrUnparseableValues() {
    #expect(RetryAfterHeader.parse(nil) == nil)
    #expect(RetryAfterHeader.parse("") == nil)
    #expect(RetryAfterHeader.parse("   ") == nil)
    #expect(RetryAfterHeader.parse("tomorrow") == nil)
    #expect(RetryAfterHeader.parse("2026-07-24T00:00:00Z") == nil)
    #expect(RetryAfterHeader.parse("1e2") == nil)
  }
}
