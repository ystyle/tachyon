p = '/home/ystyle/Projects/Cangjie/tachyon/tachyon/src/detached.cj'
s = open(p).read()
s = s.replace('''    let n = ctx.resp.header.count()
    var i: Int64 = 0
    while (i < n) {''','''    // 特殊头不在普通头表里，先补上（否则测试/适配器读不到 Content-Type）
    let ht = ctx.resp.header
    if (ht.contentTypeStr.size > 0) {
        out.headers.add(("Content-Type", ht.contentTypeStr))
    } else if (!ht.contentType.isEmpty()) {
        out.headers.add(("Content-Type", ht.contentType.toStr()))
    }
    let n = ht.count()
    var i: Int64 = 0
    while (i < n) {''')
open(p, 'w').write(s)
print('snapshot includes content-type')
