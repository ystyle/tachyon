package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class MultipartTest {
    @TestCase
    func testExtractBoundary(): Unit {
        let b1 = extractBoundary(Bytes("multipart/form-data; boundary=abc123".toArray()))
        @Expect(b1.isSome(), true)
        match (b1) { case Some(v) => @Expect(v, "abc123"); case None => @Expect(false, true) }

        // 引号包裹
        let b2 = extractBoundary(Bytes("multipart/form-data; boundary=\"a b\"".toArray()))
        match (b2) { case Some(v) => @Expect(v, "a b"); case None => @Expect(false, true) }

        // 非 multipart
        @Expect(extractBoundary(Bytes("application/json".toArray())).isNone(), true)
    }

    @TestCase
    func testParseFieldsAndFile(): Unit {
        let boundary = "X-BOUND"
        let body = "--X-BOUND\r\n" +
            "Content-Disposition: form-data; name=\"title\"\r\n" +
            "\r\n" +
            "Hello\r\n" +
            "--X-BOUND\r\n" +
            "Content-Disposition: form-data; name=\"up\"; filename=\"a.txt\"\r\n" +
            "Content-Type: text/plain\r\n" +
            "\r\n" +
            "file-content\r\n" +
            "--X-BOUND--\r\n"
        let form = parseMultipart(Bytes(body.toArray()), boundary)
        @Expect(form.count(), 2)
        match (form.field("title")) {
            case Some(v) => @Expect(v.toStr(), "Hello")
            case None => @Expect(false, true)
        }
        match (form.file("up")) {
            case Some(p) =>
                @Expect(p.fileName, "a.txt")
                @Expect(p.contentType, "text/plain")
                @Expect(p.data.toStr(), "file-content")
            case None => @Expect(false, true)
        }
    }

    @TestCase
    func testEmptyBody(): Unit {
        let form = parseMultipart(Bytes(Array<Byte>(0, repeat: 0)), "X")
        @Expect(form.count(), 0)
    }
}
