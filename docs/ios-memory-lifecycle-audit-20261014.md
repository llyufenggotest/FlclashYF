# FlClashYF iOS 内存峰值与生命周期审计（本地已验证，不是设备安全认证）

## 范围与冻结基线

- 只在 `F:/Temp/oix-test/FlclashYF-095-repair-memory`、分支 `repair/20261014-ios-memory` 修改。
- parent 基线 `d4f707b7ed80d1a9eb2d0de07120bb83f4e228ce`，mihomo 基线 `8009bd7efd28290f19863be9aba62018aeae2a18`，sing-shadowsocks2 `0e35d2749fdc58d18dd7d612482adbfbd362c8f3`。
- 原 dirty 目录未操作；集成目录只用作 worktree/shared clone 来源。没有 push、CI dispatch、全端 build 或 Release。
- 禁区 adapter/outbound 的 xhttp/snell/vless 及 transport/xhttp/vless 未修改；Swift、规则算法、MRS prewarm、旧 runtime 保护、RPC token/generation、stop one-shot、兼容 dylib 均未修改。

## 日志证据边界（不能用日志缺失伪造内存结论）

`memory/log_summary.json` 从两个用户文件只输出固定标记、计数、时间、大小，不输出 payload、配置或 secret：

- Oix：15,276 bytes，18:34:49–18:34:55；setup 标记 1，初始化配置标记 3，closed stale 标记 91。
- backstone（保留用户文件原拼写）：532,603 bytes，18:59:21–19:00:29；setup 标记 2；debug 日志 2002；health start 4 / finish 5（窗口不完整，不能将不配对计数当 goroutine 泄漏）。
- 两文件均是 Dart `Log(...)` 导出，不是 App Group native/switch diagnostics；heartbeat、footprint、reclaim、rpc_received、rpc_reply 全缺失。因此 NE phys_footprint、RPC 并发、回收收益、jetsam 原因全部**未知**，不是 0 MB / 0 并发。
- 源码注释中的历史 48–50 MiB 死亡线不是这两个日志的证据，也不是所有 iOS 版本/设备通用保证。OS jetsam 记录需另取。

## 三处确证漏洞与最小修复

### 1. terminal Close 之后，Fetcher 的晚回调仍提交（确证）

原 `Fetcher.Close()` 只 cancel ctx/close 已有 watcher；不合作的 Read 或已入 parser 的工作可继续 `vehicle.Write`、hash/updatedAt 更新、`onUpdate`；`InitialLocal()` 在 Close 后还能创建 watcher。重复 InitialLocal 还会替换旧 watcher 而不 close。

- RED：`fetcher-red.txt`，三个生产行为测试真实失败：late read err=nil / updates=1 / writes=1、SideUpdate accepted、watcher restarted。
- 修复：生命周期 mutex + terminal closed；最终 closed 检查与文件/hash/callback 提交同一锁；parser/Read 在锁外；Close 不 join 不可取消 parser；background admission 幂等；Initial 在已 cancel 时尽早拒绝。
- GREEN：晚读、晚解析、SideUpdate、watcher 重启/重复初始化、坏规则保持旧 file/hash 的测试及 25 次重复均通过。
- 边界：Close 会等已进入短提交段的文件 Write/onUpdate 完成。现有 onUpdate 不重入 Fetcher.Close；此内部回调不能将来改成重入 Close，否则会锁死。没有承诺任意慢文件系统能 bounded close。
- 仍保留：已在 parser 的 CPU/内存分配不可取消；本修复只阻止其晚提交。parser 自身可能预写 sidecar，不能把“无 vehicle commit”夸大为“一切 parser 副作用可回滚”。原 hash/updatedAt 读取与更新的并发覆盖不完整，需要 race 工具/后续快照审计。

### 2. 单次 HTTP helper 的 Transport 无人回收（确证）

`component/http.HttpRequest` 每请求 new Transport/Client；响应 body close 后 idle socket/读写 goroutine 留至 30 秒 IdleConnTimeout。下一请求又 new transport，根本无法复用这个池。

- RED：`http-red.txt`，本地 httptest 真 socket + injected Dialer；ReadAll + Body.Close 后 1 秒 socket 仍未关闭。
- 修复：body wrapper 在 Body.Close 后 CloseIdleConnections；Do 出错时也清闲池。不改响应字节、规则、协议和 TLS 选项。
- GREEN：同测试、25 次重复及 default/lowmem 包门禁通过。
- 边界：实测覆盖 HTTP/1 loopback；HTTP/2 使用 Transport 官方 CloseIdleConnections 能力但本次没有实测 h2/iOS；调用方仍必须 Close body；不能回收仍活跃的连接或代替控制峰值。

### 3. wrapper releaseConfig/shutdown 留存 proxy runtime（确证）

wrapper 清 currentConfig / 强制 GC，`executor.Shutdown` 退休 rule snapshot 却不清 tunnel 的 process-global proxies/providers；健康检查 ctx/节点 slice 仍可活着。InvalidateAllProxies 只是缓存失效，不是删 provider。

- RED：`wrapper-red.txt`，release 和 shutdown 两路径各显示 closes=0/providers=1/proxies=1。
- 修复：在 configMu 所有权内、executor.Shutdown 后、GC 前 `tunnel.UpdateProxies(nil,nil)`，走现有 stale-provider Close 通路。没有把 stopTun 变成 shutdown，也没有破坏暂停/重启继续使用配置的语义。
- GREEN：两路径关闭一次、map 空；wrapper 全包 default / with_low_memory 均通过。
- 边界：此路径实际多用于 Runner releaseAppCore；NE stopTunnel 目前调用 stopTun/stopListener 而非 shutdown。不能称本修复证明 NE stop 后整个 Go process 退出/释放。正在使用/返回中的 proxy 可暂时保有引用；不得粗暴 Close 每个 outbound，以免破坏正在使用的旧 runtime，协议 teardown 由对应 owner 审计。

## 回收入场与资源审计矩阵

| 风险 | 分类 | 证据与保留限制 |
|---|---|---|
| phys_footprint 与 Go Sys 不等价 | 确证源码 | heartbeat 用 TASK_VM_INFO.phys_footprint；memory.go Sys 含保留/已释放 Go 页，漏 native/mmap/Swift/dylib。不能用 Sys 认证 jetsam 安全。 |
| GOMEMLIMIT=32 MiB 是软预算 | 确证源码/Go机制 | lowmem.go SetMemoryLimit；live heap 大于目标、单次分配/解析/native buffer 可越限；不是 RSS/footprint 上限。 |
| reclaim 时间滞后 | 确证源码 | heartbeat 1s + 200ms leeway，启动 quickSetup 重负载在 heartbeat start 前；阶段 diagnostics 只是边界点，仍漏单步短峰。reclaim 在独立队列同步跑 GC；applyConfig 自带 GC/FreeOSMemory，但无与 heartbeat 的统一 admission。不能救已经超 jetsam 的峰。 |
| 阈值/cooldown | 确证源码，设备收益未知 | 30 warning / 38 reclaim，连续无效后 44 / 最多120s；本次不随意改。旧注释“48仍及时回收”并不能覆盖120s窗口内突增。 |
| timer stop/late handler | 源码风险，未行为确证 | heartbeat main start/stop + worker 写策略，没有 drain/owner token；cancel 不保证已执行 handler 完成，可能晚 GC/晚日志或 restart 数据竞争。未修改 Swift，因为本机无 Swift，不伪称 runtime TDD。需 macOS harness 的 blocking-reclaim stop/start 交错测试。 |
| OS pressure source | 源码风险 | 已 cancel 的 source 事件转 main 后读取 current source，可能读取新 generation；只 diagnostics 不执行策略，本次不修改。 |
| Swift startup/stop owner | 保护已保留，行为未知 | activeCleanup/main queue + coreSetupOwner 阻止旧 quickSetup 未回调时重叠启动；lifecycleGeneration/cleanup 一次性完整保留。 |
| health goroutine | 部分确证 | 替换旧 provider 已有 Close；本次补 wrapper shutdown retirement。HealthCheck.proxies/extra/interval 有无统一锁的读写，Initial 可多次起 process；SuspendHealthCheck 只是入口 bool，不取消已跑 probes。未断言观测泄漏；Windows 无 gcc，race 门禁未跑通。 |
| URLTest peak admission | 确证源码 | ios && with_low_memory process budget active=8，queued=32；wrapper also 8；default/Windows -tags with_low_memory **不激活 iOS 专有 limiter**。已跑 budget 测试但不冒充 iOS variant。取消保留容量至旧工作退出，不提前放槽，保护已有逻辑。 |
| Rule/MRS rollback | host GREEN | 全套 sidecar freshness/corruption/full-rule/prewarm/reuse/old snapshot lease/retire/预检失败保留旧 runtime 测试 default/lowmem 通过；没有裁规则/删除 prewarm。旧 snapshot reader 不退出会使退休对象继续保留，5s shutdown wait 是有界等待，不是必然释放。 |
| command RPC 并发 | 确证源码风险 | Runner 控制8个请求且为配置留1槽，但 server drain 无 cap，客户端超时释放槽不取消已跑 core；重复 wave 能超过8，server inFlight token only 防晚 response，不阻止 core 晚 mutation；go invokeMethod 每次起 goroutine。不加短 server deadline破坏120s配置；需要跨file/providerMessage统一 actual-occupancy/cancel contract 再改。 |
| RPC buffer 字节 | 确证源码风险 | Data(contentsOf req) 无大小 cap；闭包持有请求直至 response；req→JSON/Go string 与 response/data 会重叠，response payload 不受磁盘 TTL限制。不能随意给小配置上限/删请求；应先测 request/response 分布并显式协议错误契约。 |
| diagnostics cap | 确证源码风险 | NativeDiagnosticLog 磁盘4MiB + 单core line截4096，不是queue内存cap；append async 把字符串无限入队；rotate Data(contentsOf whole log) + retained tail复制导致暂时重叠。SwitchDiagnostics 同步2MiB，在任意超大旧文件恢复时也需审计读取路径；文件上限≠工作集上限。 |
| event IPC cap | 确证源码风险 | 最终event files 10且generation保护已保留；每10事件prune可暂时超过10，Swift dispatch pending Data没有byte/job cap；磁盘去旧文件不清在内存排队闭包。 |
| outbound/net transport | 部分确证/未知 | 仅修 one-shot helper。xhttp/snell/vless retain/preconnect/复用连接预算超本owner，未修改；有发现由parent/对应agent验证，不可据本报告宣布全部协议内存安全。 |

## 峰值预算：建立账本，而不是从 heap 测试编造设备上限

必须以 NE 单进程 `phys_footprint` 建预算：

`峰值 = native基础 + Go live/stack/runtime + old/new config重叠 + rule原始/压缩/解码/matcher重叠 + 活跃TLS/协议预连 + RPC请求/响应/JSON副本 + Swift/log/event pending buffers + allocator碎片/不可立即回收页`。

- 连续 reload 必须保留旧 runtime 服务，不能删旧配置“省峰值”；预算要计完整 old+new，复用已验证 matcher 有帮助但不同规则仍需双份。
- 12000 条完整 Domain/IPCIDR fixture 的本机 Go TotalAlloc：default 13,000,544 / 11,169,120 bytes；lowmem 11,745,216 / 10,565,784 bytes（`mrs-heap-*.txt`）。**TotalAlloc 是累计分配，不是同时live峰、NE footprint 或真实大订阅安全证明**。该测试还验每条规则与坏MRS拒绝。
- 没有原生 base、各协议峰、request byte峰、jetsam entitlement/limit，当前无法给“安全总峰值≤X MiB”。32MiB Go软限制不可加个固定差值来认证。
- 用设备实测可持续上限 L 与尾延迟留白 R，逐项验证 `observed transient footprint + R < L`；本次不宣称 L=48/50 固定，不能据任意阈值删除完整规则/协议功能。

## 已执行门禁与未执行门禁

环境：Windows/amd64，Go1.26.5，GOCACHE `F:/build-caches/go-build`，GOMODCACHE `F:/tools/go-mod-cache`，CGO_ENABLED=0。go list -m 已核实 wrapper replace 指向本 worktree 的两个 submodule。

- `verification.json`：mihomo 10包 default/with_low_memory + wrapper全包 default/with_low_memory + resource/http 25次重复 + targeted vet + wrapper vet 全通过。
- `ios-static-gates.txt`：32 tests，30通过、2明确skip；其中 file-RPC Python 模型不是Swift行为。SwitchDiagnostics/heartbeat 脚本 main 不会由unittest运行，因此其原生tests**未执行**。
- `race-blocked.txt`：显式 CGO_ENABLED=1 时 gcc missing。race detector **未验证**；常规确定性交错tests不是它的替代。
- 无 Swift/xcrun/Xcode：Swift行为、ObjC bridge编译、iOS arm64 build/link、IPA/dylib packaging、device footprint 全**未验证**。没有执行正式 CI/Release。
- file patch helper 的单文件 lint 在模块 cwd之外可能报未定义/missing module；真正模块 go test/vet 已通过，未为此改 go.mod/go.sum/cache或其他工作树。

## 朋友真机验收与 CI 闭环（待parent执行，非已完成）

1. macOS CI先跑 heartbeat、SwitchDiagnostics、provider retry、real lifecycle harness，新增blocking-reclaim stop/restart交错案例；启用 -race 对resource/http/provider/rules/tunnel/wrapper验锁顺序，再编译NE/Runner ios arm64 debug/unsigned测试包并验lowmem variant与兼容dylib。无正式Release。
2. 设备记录model/iOS/signing/安装渠道/精确parent&core SHA；冷启动分别Oix/backstone及全部其他已支持协议；规则完整配置不缩减，缓存冷/热都测。
3. 持续下载/多并发短连接 + 自动health与手动batch URLTest + dashboard RPC，A→B→C不同完整规则profile连续切20次（数字是验收工作量，不是安全阈值），包括坏MRS/缺artifact/配置超时。验证旧runtime不中断，错误明确、全rule count/命中一致、late generation不污染最新配置。
4. foreground/background、锁屏20min、睡眠唤醒、Wi-Fi/蜂窝、stop快速start；在heavy quickSetup期间stop，再立即start，确认旧owner回调抑制、无误stop新core；stop后真实goroutine/probe/idle socket下降需要原生/Go双账本。
5. 导出 **ios-necore-native.log + ios-switch-NECore.log + ios-switch-Runner.log**；保留phase footprint、request/response bytes、goroutines、reclaim before/after与配置generation；只提交已脱敏标记，绝不发完整配置/URL/password。另取Settings Analytics JetsamEvent/termination reason；缺它不能归因jetsam。
6. 普通heartbeat采样只给下界；用Instruments/设备可用的高频 footprint采样捕获startup/phase内部峰，核对同一NE PID。至少记录cold峰、reload峰、稳定平台、回收收益/耗时、失败瞬间与baseline趋势；确认无跨switch上升趋势不等于理论无泄漏。
7. 如果完整规则+协议在最小现实并发仍超设备预算，应明确拒绝启动并保留旧runtime/请求上移Runner准备，不裁rule、不丢协议、不假设GC能约束单次峰值。

## 交付文件

parent：`core/hub.go`、`core/lifecycle_retention_test.go`、本报告、`core/mihomo` gitlink。
core：`component/resource/fetcher.go`、`fetcher_lifecycle_test.go`、`fetcher_interleaving_test.go`；`component/http/http.go`、`http_lifecycle_test.go`。
所有可复查RED/GREEN、脚本、summary在 `F:/Temp/oix-test/evidence/flclashyf-20261014-repair/memory/`。提交SHA见该目录 `commits.json`。
