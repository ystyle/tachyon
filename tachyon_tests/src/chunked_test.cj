package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ChunkedTest {
    func size(s: String): Int64 {
        return ChunkedReader().parseChunkSize(Bytes(s.toArray()))
    }

    @TestCase
    func testParseSize(): Unit {
        @Expect(size("a"), 10)          // 十六进制
        @Expect(size("1a"), 26)
        @Expect(size("0"), 0)
        @Expect(size("ff"), 255)
        @Expect(size("A"), 10)
    }

    @TestCase
    func testParseSizeWithExt(): Unit {
        // "1a;ext=val" -> 26
        @Expect(size("1a;ext=val"), 26)
    }

    @TestCase
    func testInvalid(): Unit {
        @Expect(size("xyz"), -1)
        @Expect(size(""), -1)
    }
}
