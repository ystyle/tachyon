package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class BytesTest {
    @TestCase
    func testSliceIsView(): Unit {
        let a: Array<Byte> = "0123456789".toArray()
        let b = Bytes(a, 2, 4)
        @Expect(b.size(), 4)
        @Expect(b[0], UInt8(50))  // '2'
        @Expect(b.toStr(), "2345")
    }

    @TestCase
    func testEqualsIgnoreCase(): Unit {
        let a = Bytes("Content-Type".toArray())
        @Expect(a.equalsAsciiIgnoreCase("content-type"), true)
        @Expect(a.equalsAsciiIgnoreCase("content-TYPE"), true)
        @Expect(a.equalsAsciiIgnoreCase("content-typ"), false)
    }

    @TestCase
    func testIndexOf(): Unit {
        let a = Bytes("a=b&c=d".toArray())
        @Expect(a.indexOf(UInt8(61), 0), 1)   // '='
        @Expect(a.indexOf(UInt8(61), 2), 5)
        @Expect(a.indexOf(UInt8(120), 0), -1) // 'x'
    }

    @TestCase
    func testStartsWith(): Unit {
        let a = Bytes("HTTP/1.1".toArray())
        @Expect(a.startsWith("HTTP".toArray()), true)
        @Expect(a.startsWith("HTTPS".toArray()), false)
    }
}
