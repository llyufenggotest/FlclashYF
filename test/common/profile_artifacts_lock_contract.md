# ProfileArtifacts 跨 isolate 锁门禁

## 协议与边界

- 不改 profile/source 生产路径及 undo journal、commit、restore 顺序。
- 每个 caller 先用 `File.create(exclusive: true)` 占有 `<profile>.isolate-lock`，再打开既有 `<profile>.lock` 获取非阻塞 exclusive OS lock。POSIX exclusive create 为 `open(O_CREAT|O_EXCL)`（Linux `openat64`）；不会像 fcntl 一样把同进程 isolate 视作同一个 owner。
- marker 写入 `pid:128-bit random nonce`。PID 仅诊断，绝不用于判死/抢锁。没有按时间清除、PID 活性猜测、额外服务或 bridge dependency。
- 只有创建成功者删除 marker，且先 unlock/close OS handle。close 失败或 owner 不匹配留 marker fail-closed。竞争者从不 delete/rename marker。
- isolate 内 queue 等前驱最多 30 秒；跨 isolate/process marker + OS 锁获取共用另一个 30 秒预算，每次异步等待 20ms。合计最坏约 60 秒，IO 系统调用自身耗时不在硬实时保证内。operation 执行时间不限制，不是 lease。
- 正常/handled failure 释放；进程 crash 或持锁 isolate 被 kill 可能留下 marker，后续调用在超时后拒绝进入。**不宣称自动恢复 abandoned lock。** 运维恢复必须先停止所有会访问该 profile 的进程/isolate（包括后台实例）并保证期间无重启/新 contender，再清除 marker，然后首次 `run` 按既有 journal 恢复。不能在线按年龄/PID 清锁，不能删 OS lock 文件。
- 本协议只覆盖全部使用新版 `ProfileArtifacts.run` 的 cooperating callers、本地支持 exclusive create 的文件系统、相同 profile 路径；不支持新旧实例并行混用、路径别名/外部直接改 marker、网络 FS 语义保证或 power-loss fsync 保证。

## 本地 Windows 门禁

```sh
dart test/common/profile_artifacts_lock_contract.dart
dart analyze lib/common/profile_artifacts.dart test/common/profile_artifacts_lock_contract.dart
```

Standalone fixture：8 isolate 同一启动 barrier，共 24 次 publication，主 isolate 测 `lockActive<=1`；4 独立 child 用 exclusive sentinel 检测跨 process 重叠；杀掉持锁 child 后要求内部 30 秒 TimeoutException（不能靠测试外层 timeout 蒙混），保留 marker，fixture 在确知其 child 全退出且独占临时目录后手工清理，再验证旧 journal 成对恢复及新 owner 释放。无测试 seam，真实 production helper。

## 真实 macOS CI 必须执行（未运行不算通过）

macOS runner 安装 Dart 3.13.2，完整 checkout 包含 baseline `348121614d7b0000db07202ec99443df24c3e2c9`（fetch-depth: 0），调用：

```sh
bash test/common/profile_artifacts_macos_gate.sh
```

脚本拒绝非 Darwin，抽取 immutable baseline helper + 同一个 fixture，在真实 Dart macOS 运行 isolate barrier。必须 baseline 非零且由 `lockActive maximum>1` 断言失败，随后新版完整 contract 和 analyze 必须绿。Windows baseline 本就能通过 isolate/file-lock 测试；其 crash-policy 红不作为 POSIX 互斥 RED 证据。

允许 scope 仅 production helper + tests/文档，故这里只交付可供 CI 调用脚本，不改 workflow、不 push。父任务必须安排 macOS runner 真跑并收集日志再解除 POSIX 验收 blocker。

## 证据

`F:/Temp/oix-test/evidence/flclashyf-20261014-repair/template/posix-lock-fix/`：`results.json`、Windows baseline/candidate、analyze、focused rollback/backup logs，Dart 3.13.2 `file_macos.cc`/`file_linux.cc`/`file_win.cc` 完整源码及 SHA256。

macOS SDK source: https://github.com/dart-lang/sdk/blob/3.13.2/runtime/bin/file_macos.cc （`File::Create`）；源码说明原子机制，不替代真实 macOS 执行证据。
