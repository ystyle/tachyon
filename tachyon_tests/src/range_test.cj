package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class RangeTest {
    func r(s: String, size: Int64): ?RangeSpec {
        return parseRange(Bytes(s.toArray()), size)
    }

    @TestCase
    func testBasic(): Unit {
        let x = r("bytes=0-4", 20)
        @Expect(x.isSome(), true)
        match (x) {
            case Some(v) =>
                @Expect(v.start, 0)
                @Expect(v.end, 4)
            case None => @Expect(false, true)
        }
    }

    @TestCase
    func testOpenEnd(): Unit {
        // bytes=10- -> 10..size-1
        match (r("bytes=10-", 20)) {
            case Some(v) =>
                @Expect(v.start, 10)
                @Expect(v.end, 19)
            case None => @Expect(false, true)
        }
    }

    @TestCase
    func testSuffix(): Unit {
        // bytes=-5 -> 最后 5 个字节
        match (r("bytes=-5", 20)) {
            case Some(v) =>
                @Expect(v.start, 15)
                @Expect(v.end, 19)
            case None => @Expect(false, true)
        }
    }

    @TestCase
    func testInvalid(): Unit {
        @Expect(r("notbytes=0-4", 20).isNone(), true)
        @Expect(r("bytes=abc", 20).isNone(), true)
    }
}
