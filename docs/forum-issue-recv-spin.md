### 系统环境 | System Environment

- OS: Arch Linux（滚动更新，内核 6.x）
- Cangjie: cjc 1.2.0（cjnative，x86_64-unknown-linux-gnu）
- 机器：AMD Ryzen 7 7840HS（8 核 16 线程），2.5GbE
- 被测程序：纯 Cangjie HTTP/1.1 服务端（只回 `200 Hello, World!`），256 条长连接、约 37 万 req/s
- 采样方式：`cjprof record -f 499 -p <pid>` 采样 10 s（宿主机 sudo 不可用，在 privileged 容器内完成）
- 源码核对：`cangjie_runtime` 的 `release/1.2`（HEAD `8e6100a`，v1.2.1）与 `main`（`e927f24`）
  在本文涉及的 `sock.cpp` / `sock_impl.h` 上 `git diff` 输出为空，即下述代码就是 1.2.0 实际运行的版本

### 问题描述 | Bug Description

高并发 TCP 服务端的热点集中在运行时 socket 读取路径，其中 **16.72% 的采样落在 `sched_yield` 上**（self 时间）。对照 runtime 源码，来自 `SockRecvNonBlockGeneral` 的自旋循环：

`runtime/src/CJThread/src/aio/sock/src/sock.cpp:1634`

```cpp
unsigned int freeThreshold = schdProcessor->processorNum / PROCESSOR_FREE_RATIO;   // processorNum / 2

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
    (void)sched_yield();                       // ← 无条件执行
} while (ret == EINTR || ret == 0 || (ret == EAGAIN && scheduleFree));
```

常量：`RECV_MAX_CYCLES = 15`、`PROCESSOR_FREE_RATIO = 2`（`aio/sock/include/inner/sock_impl.h:41-42`）。

**问题一：`sched_yield()` 在不会再自旋时也执行**

当 `scheduleFree == false`（空闲处理器不足，或已达到 15 轮上限）时，循环条件下一次判断必然为假、函数返回 `EAGAIN`，上层 `TcpSocket::read` 会立刻 park 当前 cjthread。这一次 `sched_yield()` 完全多余——park 本身就是让出 CPU。

**问题二：自旋判据在 processorNum 超过物理核数时恒真**

`freeNum > processorNum / 2`：若 `cjProcessorNum` 设得大于物理核数，则总有一半 "processor" 永远空闲，判据恒成立 → 每次读都自旋满 15 轮，每轮一次 `recv` + 一次 `sched_yield`，即**每次读最多 30 次系统调用**。

### 复现步骤 | Reproduction Steps

1. 写一个最小 Cangjie TCP/HTTP 服务端（`std.net` 即可），只回固定 body；
2. 用压测工具（本文用 bombardier，128~256 条长连接）打满，使其达到数十万 req/s；
3. `cjprof record -f 499 -p <pid>` 采样 10 s 后 `cjprof report`，可看到 `sched_yield` 的 self 占比在 10%~17% 量级：

```
Children        Self    Symbol
  43.28%       1.12%    CJ_MRT_SockRecvNonBlock
  24.82%       1.92%    CJ_MRT_SockRecvNonBlockGeneral
  16.72%      16.72%    sched_yield
```

4. 交叉验证问题二：同一服务端分别以不同 `cjProcessorNum` 启动，256 连接、20 s：

| cjProcessorNum | QPS | 进程平均占用核数 |
|---|---:|---:|
| 默认（=8） | 358,726 | 4.92 |
| 8 | 355,518 | 4.32 |
| 16 | 354,666 | 4.94 |
| **32** | **326,480** | **7.99** |

设为 32（超过物理核数）时 **CPU 用得更满、吞吐反而下降 9%** —— 与"自旋条件恒真、空转"的解释一致。

5. `sched_yield()` 单次成本实测（另写 C 程序，无可运行线程时约 **487 ns/次**）。
   按 profile 的 16.7% × 5 核 ÷ 37 万 req/s ≈ **2.2 µs/请求**落在 `sched_yield` 内，
   换算约 **4~5 次/请求** —— 说明不只是"退出前那一次"，自旋分支确实在触发。

### 期望效果 | Expected Behavior

1. `EAGAIN` 且不再自旋时不要 `sched_yield()`，直接返回让上层 park。例如：

```cpp
if (!(ret == EINTR || ret == 0 || (ret == EAGAIN && scheduleFree))) {
    break;                 // 反正要 park，不必再白让一次 CPU
}
(void)sched_yield();
```

2. 自旋判据加入上限或按物理核数钳制（如 `min(processorNum, cpuNum)`），避免 `cjProcessorNum` 超配时无限自旋；
3. 自旋次数 15 次对 "发完请求、等下一轮数据" 的 HTTP 负载收益很低（等到的概率小，park/unpark 更省），建议复核该取值。

### 源码/附件 | Code & Attachments

- runtime 源码位置：`runtime/src/CJThread/src/aio/sock/src/sock.cpp`（`SockRecvNonBlockGeneral`）、`runtime/src/CJThread/src/aio/sock/include/inner/sock_impl.h`（常量）
- 完整复现材料（profile 原始数据、火焰图、压测脚本、C 语言 `sched_yield` 成本探针）可按需提供
- 影响面：所有基于 `std.net` 的高并发 I/O 服务端都在这条路径上。对照的 `stdx.net.http` 同样经
  `DopraTcpSocketImpl::readImpl` → `CJ_MRT_SockRecvNonBlock`，其 profile 中 `sched_yield` 占 5.89%
  （绝对值更小是因为它自身业务开销更大、把比例摊薄了）
