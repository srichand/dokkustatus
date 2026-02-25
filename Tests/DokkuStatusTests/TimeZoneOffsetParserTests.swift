import XCTest
@testable import DokkuStatus

final class TimeZoneOffsetParserTests: XCTestCase {
    func testNormalizedUTCOffsetAcceptsCompactAndColonFormats() {
        XCTAssertEqual(TimeZoneOffsetParser.normalizedUTCOffset("+0530"), "+0530")
        XCTAssertEqual(TimeZoneOffsetParser.normalizedUTCOffset("-05:00"), "-0500")
    }

    func testSecondsFromGMTParsesSignedOffsets() {
        XCTAssertEqual(TimeZoneOffsetParser.secondsFromGMT(offset: "+0530"), 19_800)
        XCTAssertEqual(TimeZoneOffsetParser.secondsFromGMT(offset: "-0500"), -18_000)
        XCTAssertNil(TimeZoneOffsetParser.secondsFromGMT(offset: "0500"))
        XCTAssertNil(TimeZoneOffsetParser.secondsFromGMT(offset: "+0A00"))
    }
}
