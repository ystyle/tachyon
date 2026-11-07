package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class CookieTest {
    func parse(s: String): CookieView {
        let c = CookieView()
        c.reset(Bytes(s.toArray()))
        return c
    }

    @TestCase
    func testBasic(): Unit {
        let c = parse("a=1; b=2")
        @Expect(c.count(), 2)
        @Expect(c.get("a").toStr(), "1")
        @Expect(c.get("b").toStr(), "2")
    }

    @TestCase
    func testQuoted(): Unit {
        let c = parse("k=\"v v\"")
        @Expect(c.get("k").toStr(), "v v")
    }

    @TestCase
    func testMissing(): Unit {
        let c = parse("a=1")
        @Expect(c.get("zzz").isEmpty(), true)
    }
}

@Test
class SetCookieTest {
    @TestCase
    func testBasic(): Unit {
        let b = SetCookieBuilder("sid", "abc")
        @Expect(b.toString(), "sid=abc")
    }

    @TestCase
    func testFull(): Unit {
        let b = SetCookieBuilder("k", "v").setPath("/").setDomain("e.com").setMaxAge(60).setHttpOnly().setSecure().setSameSite("None")
        @Expect(b.toString(), "k=v; max-age=60; domain=e.com; path=/; HttpOnly; secure; SameSite=None")
    }

    @TestCase
    func testDelete(): Unit {
        // maxAge < 0 输出 max-age=0（立即删除的约定）
        let b = SetCookieBuilder("k", "").setMaxAge(-1)
        @Expect(b.toString(), "k=; max-age=0")
    }
}
