package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class HttpDateTest {
    @TestCase
    func testFormatEpoch(): Unit {
        // 1970-01-01 00:00:00 UTC 是周四
        @Expect(formatHTTPDate(0), "Thu, 01 Jan 1970 00:00:00 GMT")
    }

    @TestCase
    func testFormatKnown(): Unit {
        // 2026-11-07T23:30:00Z
        @Expect(formatHTTPDate(1794094200), "Sat, 07 Nov 2026 23:30:00 GMT")
    }

    @TestCase
    func testRoundTrip(): Unit {
        let v = Bytes("Sat, 07 Nov 2026 23:30:00 GMT".toArray())
        @Expect(parseHTTPDate(v), 1794094200)
    }

    @TestCase
    func testParseInvalid(): Unit {
        @Expect(parseHTTPDate(Bytes("not a date".toArray())), -1)
        @Expect(parseHTTPDate(Bytes("".toArray())), -1)
    }
}
