# tachyon

fasthttp 风格、零分配的仓颉 HTTP/1.1 服务端。**仅依赖 `std.*`**。

## 硬约束（违反即不可接受）

1. **主模块零 stdx**。`tachyon/cjpm.toml` 与 `tachyon/src/` 里不得出现任何 stdx 相关配置或 import。
   判据（CI 必须跑）：
   ```shell
   ! grep -rq 'stdx' tachyon/cjpm.toml tachyon/src/ || (echo "主模块引入了 stdx!"; exit 1)
   ```
   原因：仓颉**没有条件编译**，依赖树里任一包 import stdx，整条链的 `cjpm build` 都要
   `${CANGJIE_STDX_PATH}`，且没被用到的 stdx 包也照编。主模块必须对所有下游零配置。

2. **`-O2` 必须开**。`compile-option = "-O2 -Woff unused"`。
   实测：不开 75 MB/s，开了 4189 MB/s（55 倍）。漏掉不报错，只是慢。

3. **热路径不构造 `String`**。`String.fromUtf8` 带 UTF-8 校验（1 MiB ≈ 544 µs）。
   内部一律 `Bytes` 视图，只在用户显式调 `toStr()` 时转换。

4. **不做 HTTP/2 / TLS**。与 fasthttp 的取舍一致（上游也不支持 h2）。
   需要 h2 在 LB 终结；需要 TLS 用 stdx.net.tls（扩展包）。

## 测试

```shell
eval "$(cjvs env zsh)"
cjpm build -j 8
cjpm test               # 17 个单元测试
```

**测试绿了才提交**。新增功能必须配用例。

## 结构

```
cjpm.toml              [workspace]，不写任何 stdx
tachyon/               主模块（ystyle::tachyon）
  src/
    bytes.cj           Bytes 零拷贝视图
    buffers.cj         固定大小读写缓冲
    header.cj          HeaderTable（argsKV 模型）
    request.cj         请求解析
    uri.cj             URIView + 路径规范化
    args.cj            ArgsView
    response.cj        响应序列化
    status.cj          状态码表
    datecache.cj       Date 头缓存
    server.cj          Server 主循环
    ctx.cj             RequestCtx
tachyon_tests/         单元测试
```

## 已知仓颉坑（踩过的）

| 坑 | 现象 | 解法 |
|---|---|---|
| 带 `organization` 的包 | `package tachyon` 报 "package name is wrong, should be 'ystyle::tachyon'" | 包声明写 `package ystyle::tachyon` |
| 常量位置 | 常量在使用处之后定义会报 "used before being defined" | 常量必须放文件前面 |
| path 依赖名 | `"tachyon" = { path = ... }` 报 "require name different to name" | 写 `"ystyle::tachyon" = { path = ... }` |
| `mut prop` 带初始值 | `public mut prop x: Int64 = 1` 编译报错 | 用 `public var x: Int64 = 1` |
| `Duration` 位置 | `import std.time.Duration` 报 not accessible | `Duration` 在 `std.core`，`import std.core.*` |
| `String` 索引 | 取到的是 UTF-8 字节 `UInt8`，且切片会校验 UTF-8 | 全程用 `Array<Byte>` / `Bytes` |
