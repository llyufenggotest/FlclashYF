## FlClashYF VERSION

基于 FlClash Patched **0.9.7**，保留全部 YF 魔改协议、iOS 生命周期与上一版功耗优化。Android 修复候选已由用户覆盖安装验收通过；其他平台已完成构建与产物校验，不把构建成功等同真机验收。正式包使用相同产品源码重新构建，并嵌入本次 Release 更新标识。

### 本次更新与修复
- 新增仪表盘 Allow LAN 快捷开关，配置与开关状态同步。
- 更新核心 TLS 依赖及 Go 1.26.10，纳入上游 TLS 安全修复和 Sudoku 实现改进。
- 修复 Sudoku mux 在下行阻塞时重复派生 PONG 回复任务的问题，保持 PING/PONG 协议与原有背压语义。
- 修复配置切换时代理组与节点选择的归属，保留 configuration/session token、并发隔离、失败回滚和后写保护。
- 修复重置节点选择被核心拒绝后旧选择未恢复的问题。
- 修复 Android 启动状态覆盖切断分组发布依赖、导致连接正常但底部“代理”按钮及代理页面消失的问题；加入真实启动覆盖、胶囊导航点击和节点显示刷新回归。
- 修正速度图零基线，移除人为前导零点；保留紧凑双向速率布局、重绘隔离与默认零动画。

### 保留的稳定能力
- 全部私有协议、Blackstone 后缀隔离和标准 VLESS 行为；测速绕过前置代理，业务路由保持原规则。
- Oix/Snell 预连接和稳态缓冲复用，协议帧、加密及 nonce 语义保持。
- 原有 GC 去重、轻量连接计数、后台页面订阅控制、事件有界合并、原生日志与诊断优化。
- iOS NE 本地加载、RPC/mailbox 生命周期、完整规则预热、MRS 失败回滚、低内存保护和侧载资源。
- 自有更新链、GeoXZ 资源、包名与 Android 签名延续。**不包含已撤销的备用 DNS，也未新增清除 DNS 缓存功能。**

不承诺固定的耗电或温升降幅。正式标签构建的二进制与先前测试包字节不同，来源和产品代码一致。

### 下载

| 平台 | 文件 |
|---|---|
| Android arm64-v8a | `FlClash-NATIVE-android-arm64-v8a.apk` |
| Windows x64 便携版 | `FlClash-NATIVE-windows-x64.zip` |
| iOS arm64（未签名，需自行侧载签名） | `FlClash-NATIVE-ios-arm64-unsigned.ipa` |
| macOS Apple Silicon | `FlClash-NATIVE-macos-arm64.dmg` |
| macOS Intel | `FlClash-NATIVE-macos-x64.dmg` |

`version.json` 包含五个文件的大小与 SHA256，App 更新检查仅接受本仓库的对应文件。

Android 包名 `cc.llyufeng.flclash.dev`，保持原签名，可覆盖安装并保留数据。此前发布的标签和资产保持不变。
