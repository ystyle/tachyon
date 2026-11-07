package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class StatusTest {
    @TestCase
    func testCommon(): Unit {
        @Expect(statusText(200), "OK")
        @Expect(statusText(404), "Not Found")
        @Expect(statusText(500), "Internal Server Error")
        @Expect(statusText(431), "Request Header Fields Too Large")
        @Expect(statusText(503), "Service Unavailable")
    }

    @TestCase
    func testSkipBody(): Unit {
        @Expect(mustSkipBody(204), true)
        @Expect(mustSkipBody(304), true)
        @Expect(mustSkipBody(100), true)
        @Expect(mustSkipBody(200), false)
        @Expect(mustSkipBody(404), false)
    }

    @TestCase
    func testSkipContentLength(): Unit {
        @Expect(mustSkipContentLengthOnWire(204), true)
        @Expect(mustSkipContentLengthOnWire(100), true)
        // 304 允许带 Content-Length
        @Expect(mustSkipContentLengthOnWire(304), false)
    }
}
