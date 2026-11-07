# tachyon 设计文档

完整设计（含 fasthttp 源码剖析、仓颉标准库能力实测、HTTP/2 可行性分析、扩展成员规划）
在工作区文档仓：

**[`docs/plans/2026-11-07-fasthttp-cj-server.md`](../../docs/plans/2026-11-07-fasthttp-cj-server.md)**

支撑材料：

| 文件 | 内容 |
|---|---|
| `../../.scratch/notes/fasthttp-analysis.md` | fasthttp 服务端剖析（1565 行 / 423 处 file:line） |
| `../../.scratch/notes/cangjie-std-capability.md` | 仓颉标准库能力实测（828 行 / 27 个探针） |
| `../../.scratch/notes/stdx-capability.md` | stdx 能力与依赖方式实测（434 行） |
| `../../.scratch/notes/go-baseline.md` | Go 基线压测 |

## 本仓已知的取舍

见仓库根的 `AGENTS.md`「硬约束」与 README 的「不做的事」。

## 分阶段进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | Bytes / Buffers / 扫描原语 / -O2 骨架 | ✅ |
| P1 | HeaderTable / RequestParser | ✅ |
| P2 | ResponseSerializer / Server 主循环 / keep-alive / 超时 | ✅ |
| P3 | chunked body / ArgsView / URI 规范化 / Cookie | 🚧 ArgsView 与 URI 已完成，chunked 待做 |
| P4 | ObjectPool / reduceMemoryUsage / maxConnsPerIP / 零分配验收 | ⬜ |
| P5 | 静态文件 / 错误页 / 中间件 | ⬜ |
