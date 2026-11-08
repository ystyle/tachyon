p = '/home/ystyle/Projects/Cangjie/tachyon/tachyon/src/fs.cj'
s = open(p).read()
if 'public func addIndexName' not in s:
    s = s.replace('''    /** 挂载到指定前缀下（如 "/static"），会自动剥离前缀再拼文件路径 */''','''    /** 追加目录索引文件名 */
    public func addIndexName(name: String): Unit {
        var i: Int64 = 0
        while (i < indexNames.size) {
            if (indexNames[i] == name) {
                return
            }
            i += 1
        }
        indexNames.add(name)
    }

    /** 是否支持 Range 请求 */
    public func setAllowRange(allow: Bool): Unit {
        allowRange = allow
    }

    /** Cache-Control 的 max-age（秒），<=0 表示不输出 */
    public func setMaxAge(seconds: Int64): Unit {
        maxAgeSeconds = seconds
    }

    /** 挂载到指定前缀下（如 "/static"），会自动剥离前缀再拼文件路径 */''')
    open(p, 'w').write(s)
    print('FileServer setters added')
