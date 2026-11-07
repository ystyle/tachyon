package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ArgsTest {
    func parse(s: String): ArgsView {
        let a = ArgsView()
        a.parse(Bytes(s.toArray()))
        return a
    }

    @TestCase
    func testBasic(): Unit {
        let a = parse("a=1&b=2")
        @Expect(a.count(), 2)
        @Expect(a.get("a").toStr(), "1")
        @Expect(a.get("b").toStr(), "2")
    }

    @TestCase
    func testNoValue(): Unit {
        let a = parse("flag&x=1")
        @Expect(a.count(), 2)
        @Expect(a.has("flag"), true)
        @Expect(a.get("flag").isEmpty(), true)
    }

    @TestCase
    func testPlusAsSpace(): Unit {
        let a = parse("q=hello+world")
        @Expect(a.get("q").toStr(), "hello world")
    }

    @TestCase
    func testPercentDecode(): Unit {
        let a = parse("q=%E4%B8%AD%E6%96%87")
        @Expect(a.get("q").size(), 6)  // UTF-8 中文 6 字节
    }

    @TestCase
    func testMissing(): Unit {
        let a = parse("a=1")
        @Expect(a.get("zzz").isEmpty(), true)
        @Expect(a.has("zzz"), false)
    }
}
