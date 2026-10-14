# 第二轮 iOS 内存：实现、实际执行与阻塞（仅 FlClashYF）

基线 parent `7edcfb747a4a33d58bdbfa607c63b89c8f611821`，core `221931d147e9844ce1e944801f789c0c44f4bfa0`。续用原 worktree，不 reset、不改历史、不 push。原审计位于仓库外 `F:/Temp/oix-test/evidence/flclashyf-20261014-repair/memory/AUDIT.zh-CN.md`，已先读。Oix误发订阅与iOS27自签问题不在本补丁归因范围；不改兼容dylib、协议、Windows Rust、MRS规则、预热回滚或GC阈值。

## 已实现

- `NativeResourceHeartbeat.swift`：timer/start/stop/reclaim状态统一到一个worker；每次start/stop推进owner。旧owner tick在采样/日志/GC前拒绝；stop同步排空已开始GC，不能仅cancel timer就认为执行结束。新增注入sampler、testOwner/testTick确定性门禁；worker内deinit不会sync自己。既有GC threshold/cooldown/reclaim policy不变。
- `NativeDiagnosticLog.swift`：普通core log在dispatch前按64 jobs/256KiB pending预算准入（含正在执行job），单行最多8KiB且预格式化UTF8前缀有界。原生生命周期/heartbeat marker用同步背压、不被普通log洪峰丢弃。debug durable过滤保持。4MiB仅是诊断文件预算，不是配置/RPC/event限制。rotation从文件尾部seek后64KiB流式复制到同目录原子替换，不读完整遗留文件。testURL/write-gate/pending计数可真实卡住写盘检查准入上界。
- `NECoreEventQueue.swift`：callback由原ObjC单串行callback queue同步进入event worker，移除每个Data异步closure积压。沿用core/message.go已存在bulk eviction类别：仅纯log/request/dns批次标记`.lossy.json`，最多保留10个；mixed、delay ack、loaded、geoUpdate、未知事件和完整payload不裁不丢，不再overflow后整体core inactive。枚举流式，最多11个URL驻留。
- Fetcher metadata：新增独立metadataMu，统一Read的hash快照、UpdatedAt及pull-loop读、发布写。**不能把UpdatedAt直接改为lifecycleMu锁**：RuleSetProvider.MarshalJSON持readyMu，onUpdate在lifecycleMu下获取readyMu，会产生反向锁序。metadataMu在callback前释放；Initial恢复mtime受terminal Close保护。core新增真实并发metadata测试。

## 预算边界与保留功能

- diagnostic pending <=64 jobs且<=256KiB；单条8KiB；关键marker同步caller背压；写盘retained window约2MiB但逐块读取，scratch chunk64KiB。
- event NE侧待处理async payload jobs = 0；原bridge串行回调最多一个event驻留（上游core message channel仍按原256/32契约），单event不添加新字节阈值；允许完整>4MiB批次。存在一次JSON分类解析的单payload瞬态。
- **critical durable event backlog无硬文件/字节上限**：没有consumer ACK/重发契约时不能同时保证lossless与固定disk cap。本轮保证不把它们留在NE异步内存queue或批量扫描数组；需要parent确认下一阶段ACK/consumer bounded streaming。Runner CoreEventRelay仍可并发读取全部critical文件，未声称端到端内存封顶。
- heartbeat stop若已进入不可取消GC，会等该GC完成；不随意deadline放行。需要macOS/真机记录stop延迟，不能声称bounded teardown延时。

## RPC actual occupancy：安全阻塞，不盲改

代码证据：TunnelController客户端slot只约束await生命周期，timeout后core可能仍跑；PacketTunnelCommandServer.drain遍历全部req，inFlight无上限；stop清inFlight仅令publication token失效，并未取消core。Provider.handleAppMessage直接invoke绕过file server。core/lib.go invokeMethod启动goroutine，method.go safeGo另起worker；结果callback不是通用的真正handler退出证明。

因此本轮不改client/server/providerMessage error/deadline/token契约，不增配置文件4MiB cap、不释放假timeout slot。120s配置deadline保留。可合入的后续必要契约：
1. 两种transport共用同一个process实际admission账本（不能各自4 slots），区分配置mutation独占/只读保留通道；
2. callback pending与uncancellable mutation跨stop/start保留占槽；不能timeout/清inFlight当释放；
3. core真正operation exit需要桥接completion/任务计数证明，safeGo与nested async均覆盖；
4. overload排队/背压、busy回复或重试若改变现有结果，须同步修改客户端两条路径；
5. harness验证A pending→client timeout→B禁止mutate，stop/start→A退出→新generation放行，重复callback无double-release，providerMessage与file共享，120s配置不被提前淘汰；
6. request/response byte cap要来自实际产品契约，规则完整性不能牺牲。

已准备实际Swift `--rpc-blocker`：hold 16个invoke callback，验证server实际pending可超过client4并输出EXPECTED_BLOCKER_RED。这不是修复PASS，CI只确认该已知阻塞存在。

## Fetcher callback锁序独立审计

所有生产NewFetcher调用：proxy provider `pd.setProxies` 与rule provider `onUpdate`。proxy链：lifecycleMu→baseProvider.mutex→healthCheck.setProxies/auto，check在goroutine；Close只cancel healthCheck context后Fetcher.Close，未发现同步回调直接重入Close。rule链：lifecycleMu→readyMu（publish后解锁）→AcquireRuleSnapshot短configMux读锁/lease→Callback.Emit的callback RW锁，Emit仅go异步listener.ruleUpdateCallback→ruleUpdateMutex→autoRedirect。snapshot retirement等lease排空后**异步**closeProviders，不在该onUpdate栈同步Close。当前产品链未证明直接callback自Close，但泛型Fetcher任意callback自Close确会deadlock；本轮不简单把callback搬锁外破坏terminal-close。留作有证明的契约扩展。healthCheck.proxies与subscriptionInfo另有未统一同步候选，不顺手扩scope。

## 实际本机结果（Windows，无Swift/Apple SDK）

- SOURCE RED：`python scripts/test_ios_memory_round2.py --source-ref 7edcfb747a4a33d58bdbfa607c63b89c8f611821 --source-only`：6项FAIL，提交 `60f10f57f779edf54f75b022fb98df80f04795e5`。这是source gate RED，**不是Swift行为RED**。
- 当前同source gate：6项PASS；lifecycle source 5 PASS，command bridge source 5 PASS，switch wiring source 9 PASS；provider retry source 12 cases中1 Swift SKIP。
- `--require-swift`与`--baseline-native --require-swift`：退出2，NOT EXECUTED；lifecycle behavior SKIP。无Swift编译/行为GREEN。
- 真实Go：resource全包PASS；7个TestFetcher PASS（late read/parser、terminal stop、idempotent watcher、parse rollback、metadata并发）；ios_low_memory resource/rules/provider/tunnel PASS；component/http TestOneShotRequestBodyCloseReleasesTransport PASS；core wrapper message/release/memory/retention筛选PASS。adapter/provider先前筛选无匹配，不算测试。
- `go test -race ...`本机拒绝：CGO_ENABLED=0且无可用gcc。普通并发测试PASS不等race detector PASS。Go diff/source可见data race机制修复，race检测待macOS。
- Core提交 `e951c76d2ee9ade5cfb106edfaaafe114e0683e4`；未push。

## macOS真实执行命令与验收（未执行）

```sh
python3 scripts/test_ios_memory_round2.py --baseline-native --require-swift
# git show immutable parent源码编译，真实30个delay ack基线丢失须EXPECTED_BASELINE_RED
python3 scripts/test_ios_memory_round2.py --rpc-blocker --require-swift
# 真实server callback-pending=16的已知BLOCKER RED，不宣称修复
python3 scripts/test_ios_memory_round2.py --require-swift
# production三文件编译；blocked writer准入/UTF8/critical、64MiB继承文件rotation、
# blocked GC stop drain/旧owner/concurrent restart、mixed-critical与>4MiB完整事件
python3 scripts/test_ios_heartbeat.py
python3 scripts/test_ios_lifecycle_behavior.py
(cd core/mihomo && CGO_ENABLED=1 go test -race ./component/resource -count=1)
(cd core/mihomo && go test -tags ios_low_memory ./component/resource ./rules/provider ./tunnel -count=1)
```

CI `.github/workflows/ios-memory-native.yaml`使用macos-15、fetch-depth0、require-swift，workflow_dispatch且no branch restriction；现有heartbeat workflow也接入行为门禁。父需先推core再推parent以保证submodule可拉。未代父push。

真机剩余验收：完整规则量与节点数不变；完整getProxies/RPC不截断；Runner/NE分别记录SwitchDiagnostics process_id/attempt/bundle与footprint；高日志洪峰+慢文件系统时pending峰值/stop延迟；A→stop→B期间旧reclaim无跨owner；120s setup/update保留；critical ACK backlog消费/成功投递后删除；长期稳定与startup峰值实测。本轮没有历史footprint证据，**不能claim<系统memory limit或iOS27失败原因**。
