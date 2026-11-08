# [runtime] `SockRecvNonBlockGeneral` 在每次 EAGAIN 上无条件 `sched_yield()`，空转约占 HTTP 服务端 15% CPU

## 环境

- Cangjie **1.2.0**（Linux x86_64）
- 源码已按 `release/1.2` 分支（HEAD `8e6100a`，v1.2.1）核对：
  `sock.cpp` 与 `sock_impl.h` 同 `main`（`e927f24`）**逐字节一致**，即本文描述的就是 1.2.0 实际运行的代码
- 交叉验证：`release/1.2` 与 `main` 对该文件 `git diff` 输出为空
- 机器：Ryzen 7 7840HS（8 核 16 线程），2.5GbE
- 被测程序：纯 Cangjie HTTP/1.1 服务端（只回 `200 Hello, World!`），256 长连接、~37 万 req/s
- 采样：`cjprof record -f 499 -p <pid>`（采样 10 s）

## 现象

profile 里 **16.72% 的样本落在 `sched_yield` 上**（self 时间，非 children）：

```
Children        Self    Symbol
  43.28%       1.12%    CJ_MRT_SockRecvNonBlock
  24.82%       1.92%    CJ_MRT_SockRecvNonBlockGeneral
  16.72%      16.72%    sched_yield
```

同一份 profile 里，服务端自身业务代码合计只有 ~10%。

## 源码定位

`runtime/src/CJThread/src/aio/sock/src/sock.cpp:1634`：

```cpp
int SockRecvNonBlockGeneral(int fd, void *buf, unsigned int len, SocketFlag flags, int *recvLen)
{
    ...
    unsigned int freeThreshold = schdProcessor->processorNum / PROCESSOR_FREE_RATIO;

    do {
        recvRet = recv(fd, buf, static_cast<size_t>(len), flags);
        ret = errno;
        if (recvRet != -1) {
            break;
        }
        cycles++;
        // If the number of idle processors is sufficient, spin recv some times to reduce cjthread park.
        scheduleFree = (schdProcessor->freeNum).load(std::memory_order_relaxed) > freeThreshold &&
                        cycles <= RECV_MAX_CYCLES;
        (void)sched_yield();          // <-- 无条件执行
    } while (ret == EINTR || ret == 0 || (ret == EAGAIN && scheduleFree));
    ...
}
```

`RECV_MAX_CYCLES = 15`、`PROCESSOR_FREE_RATIO = 2`（`aio/sock/include/inner/sock_impl.h:41-42`）。

## 两个问题

### 1. `sched_yield()` 无条件调用（主要）

当 `scheduleFree == false`（空闲处理器不足**或**已超过 15 次）时，循环**已经要退出了**，
上层会立刻 park 这个 cjthread —— 这次 `sched_yield()` 完全是多余的。
每个 EAGAIN 多一次系统调用。

**成本实测**：单独测 `sched_yield()`（无其它可运行线程时）约 **487 ns/次**。
profile 里 16.7% × 5 核 ÷ 37 万 req/s ≈ **2.2 µs/请求**落在 `sched_yield` 内，
除以 487 ns 约合 **4–5 次 yield/请求** —— 说明不只是"退出前那一次"，自旋分支也在实际触发。

建议：把 yield 移进真正要自旋的分支，或至少退出前不 yield：

```cpp
if (!(ret == EINTR || ret == 0 || (ret == EAGAIN && scheduleFree))) {
    break;                    // 反正要 park，不要白 yield 一次
}
(void)sched_yield();
```

### 2. `freeNum > processorNum/2` 的自旋判据在超配时会失效

`cjProcessorNum` 设得比物理核数大时（例：16 线程机器上设 32），
总有一半 processor 永远空闲 → `freeNum` 常态大于 `processorNum/2` → **每次读都自旋满 15 轮**，
每轮一次 `recv` + 一次 `sched_yield`，即每请求最多 30 次系统调用。

实测（同一服务、256 连接）：

| cjProcessorNum | QPS | 进程核数 |
|---|---:|---:|
| 默认(=8) | 358,726 | 4.92 |
| 8 | 355,518 | 4.32 |
| 16 | 354,666 | 4.94 |
| **32** | **326,480** | **7.99** |

设置为 32 时 CPU 用得更多、吞吐反而更低 —— 与"自旋空转"的解释一致。

## 建议

1. EAGAIN 且不再自旋时不要 `sched_yield()`（直接让上层 park）。
2. 自旋判据加入上限，或按"处理器数 ≤ 物理核数"钳制，避免超配时无限自旋。
3. 自旋次数可从 15 降到 1–3；对 HTTP 这类"发完请求就等下一轮"的负载，
   自旋等到的概率很低，park/unpark 反而更省。

## 影响面

所有用 `std.net` 做高并发 I/O 的仓颉服务端都在这条路径上
（我们对比的 `stdx.net.http` 同样走 `DopraTcpSocketImpl::readImpl` → `CJ_MRT_SockRecvNonBlock`，
其 profile 里同样有 5.89% 的 `sched_yield`，只是被它自身更多的业务开销摊薄了）。