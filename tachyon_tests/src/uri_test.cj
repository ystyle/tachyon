package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class UriTest {
    func norm(s: String): String {
        let buf = Array<Byte>(1024, repeat: 0)
        return normalizePath(Bytes(s.toArray()), buf).toStr()
    }

    @TestCase
    func testBasic(): Unit {
        @Expect(norm("/"), "/")
        @Expect(norm("/a/b"), "/a/b")
        // 结尾斜杠保留（与 fasthttp normalizePath 一致）
        @Expect(norm("/a/b/"), "/a/b/")
    }

    @TestCase
    func testDuplicateSlashes(): Unit {
        @Expect(norm("/a//b"), "/a/b")
        @Expect(norm("///a"), "/a")
    }

    @TestCase
    func testDotSegments(): Unit {
        @Expect(norm("/a/./b"), "/a/b")
        @Expect(norm("/a/../b"), "/b")
        @Expect(norm("/a/b/../c"), "/a/c")
    }

    @TestCase
    func testPercentDecode(): Unit {
        @Expect(norm("/d%41"), "/dA")
        // 解码先于 dot-segment 处理（安全关键）
        @Expect(norm("/a/%2e%2e/b"), "/b")
    }

    @TestCase
    func testPlusIsLiteral(): Unit {
        // path 里 '+' 是字面量，不转空格
        @Expect(norm("/a+b"), "/a+b")
    }
}
