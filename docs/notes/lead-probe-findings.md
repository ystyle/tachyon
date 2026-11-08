# Lead 亲测记录（仓颉 1.2.0，仅 std，无 stdx）

> 机器：AMD Ryzen 7 7840HS，8C16T，Linux 7.2.6
> 工具链：仓颉 1.2.0（cjnative）
> 运行二进制前必须 `eval "$(cjvs env zsh)"`（否则缺 libcangjie-runtime.so）

## 1. Array<Byte> 切片是**零拷贝别名**（关键！）

```
a = [1,2,3,...]; s = a[1..4]; s[0] = 42
→ a[1] 变成 42；反向 a[2]=43 → s[1] 变成 43
```

结论：`arr[a..b]` 产生的是共享底层存储的视图。**这正是 fasthttp 零拷贝方案的基础**，
可以在同一块 per-connection buffer 上做 header/body 视图，不需要额外拷贝。

## 2. String 与字节

- `String.size` 是**字节数**；`str.toArray()` 会**拷贝**出 UTF-8 字节。
- 反过来 `String.fromUtf8(arr)` 也会拷贝。
- 所以热路径上不能"每个 header 转一次 String"——要按字节比较（见 §5）。

## 3. 线程（spawn）

| 数量 | 创建耗时 | join 耗时 |
|---|---|---|
| 100 | ~0.7–1.0 ms | ~20–37 µs |
| 1000 | ~2.4–3.2 ms | ~88–92 µs |

结论：单线程创建约 **2.4–3 µs**。Go goroutine 约 0.3–0.5 µs（stack 2KB 起）。
仓颉 spawn 是**操作系统线程级**（或用线程池做 1:1），比 goroutine 重约 5–8 倍，
但**每连接一线程**的模型在几千并发时仍可用（1000 连接 ≈ 3ms 创建开销，内存另算）。
需要实测 10k 连接时的内存与稳定性（交给 cangjie-std-probe 验证）。

## 4. 线程内异常

`spawn { throw Exception(...) }` → 异常在 `f.get()` 处重新抛出到调用方。
**但**：如果调用方不 get，异常会打到 stderr（"An exception has occurred"）并**不终止进程**。
→ 服务端每连接 spawn 时，必须在 lambda 内自己 try/catch，否则会刷 stderr。

## 5. 字节扫描吞吐（1MB buffer）

| 写法 | 吞吐 |
|---|---|
| 索引 `buf[i]` 逐字节 | ~57–64 MB/s |
| `acquireArrayRawData` + 裸指针 `p.read(i)` | ~64–91 MB/s |

结论：
- **仓颉的 `Array<Byte>` 逐字节索引不慢，但也不快**（~60 MB/s 量级）。这个数值偏低，
  说明没有做 SIMD 加速的向量化扫描；Go 的 `bytes.IndexByte` 走 AVX2 能到 GB/s 量级。
- 裸指针版本略快（1M buffer 下 91 vs 64 MB/s），但**仍不是 memchr 级**。
- **对 HTTP 解析的含义**：一个 8KB 的 header block 扫描约 130 µs？不对 —— 8KB / 60MB/s ≈ 0.13 µs。
  即**每个请求扫 header 的成本约 0.1–0.2 µs**，相对请求总成本（几 µs）是可以接受的。
  真正的问题在**每请求的固定开销**（分配、线程、syscall），不是扫描。
- 需要注意：`scanIndexed` 里每轮有边界检查，如果写成 `for (b in buf.slice(...))` 或
  `buf[i..n]` 拿视图再迭代，可能更快——待 cangjie-std-probe 验证。

## 6. 起一个能跑的 HTTP/1.1 服务端（spike）

位置：`.scratch/spike`。实现要点：
- `TcpServerSocket(bindAt:).bind()` + `accept()` 循环，每连接 `spawn`。
- 直接在 `Array<Byte>(8192)` 上找 `\r\n\r\n`，原地切出 method/path/version/headers 视图（只存下标）。
- 写响应同样直接拼字节到预分配 buffer。
- 已用 curl 验证：200 / 404 / keep-alive 都正常。

## 7. 已知坑（踩过的）

1. `struct` 的 `let` 字段必须在 `init` 里初始化，写"字段列表 + 位置构造调用"编译不过。
2. `UInt16.parse` 不存在（没有 `parse` 静态方法），要自己写。
3. `UInt8` 与 `Int64` 不能直接 `+`/`-`，要 `Int64(b)`。
4. `MonoTime` 没有 `ticks`/`toNanoseconds()` 方法，用 `(t1 - t0)` 得 `Duration` 再 `toMilliseconds()` 等。
5. 后台起服务要用 `nohup setsid ... < /dev/null &`，普通的 `&` 在 bash 工具里会随 shell 退出被杀。
