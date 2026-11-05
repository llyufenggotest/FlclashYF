## FlClashYF VERSION

基于 FlClash Patched **0.9.8**，并融合下述上游主分支后继功能。以保留绿叶 DNS 修复和 iOS 启动修复的 YF 基线继续升级，保留全部自有协议、更新链及平台能力。

### 本次升级
- 增加 sniffer 覆盖设置，与 DNS、NTP 覆盖逻辑一致；保留订阅原配置及全局模板的既有优先级和私有 DNS/hosts 依赖。
- DNS 查询页新增清空 DNS 缓存操作；iOS 运行中通过 Network Extension 执行，不把扩展失败伪装为主程序核心成功。
- 修复 TUN 授权失败后的开关状态；迟到的授权结果不得覆盖用户后续 off/on 操作。
- 修复 Windows 升级后的 helper 服务恢复。
- 融合上游主分支后继：IPv6／外部控制器快捷开关，以及 Android Tailscale 默认网络变化通知。
- 保留自有代理组 configuration/session 归属、异步刷新隔离、失败回滚及速度图零基线强化。

### 本次纳入的既有修复
- 保留绿叶配置所需的 DNS/hosts 监听依赖，iOS 监听地址按依赖收窄至 loopback，不统一强加监听端口。
- 保留 App／VPN 扩展 DNS 监听所有权切换、失败保旧事务与 reload 唤醒修复。
- 保留 iOS 启动参数传递、原始错误分类和有界诊断；未合入独立的官方 IPC echo 实验，也未重写现有资源共享架构。
- EasyTier 内置固定来源依赖，复用单一只读 WASM 编译产物，避免重启重复编译；每个 Host 的 runtime、guest memory、reactor 与 ABI 仍独立。

### 保留能力与限制
- 全部私有协议、Blackstone 后缀隔离及标准 VLESS 行为；测速绕过前置代理，业务路由规则不变。
- Oix/Snell、后台页面订阅控制、GC 去重、有界事件合并、原生日志、完整规则预热及 MRS 失败回滚均保留。
- 包名、Android 签名、自有更新链、GeoXZ 资源和 iOS 侧载资源保持；不恢复已撤销的备用 DNS。
- EasyTier 编译缓存仅首次实际使用后建立，并在进程内常驻；它不是零成本缓存。Windows 诊断测得退休后约 10.6MB Go heap 常驻，另有可执行代码／RSS 开销；**这些数据不代表 iOS 低内存实机验收**。
- iOS 包未签名，需自行侧载签名。朋友 iPad 换证书后恢复可用的报告来自上一 YF 测试基线，不代表本次 0.9.8 已获该设备验收。
- 构建、原生自动化检查与包校验不等同于新版本五端真机联网、内存或耗电验收，不承诺固定温升或续航改善。

### 下载

| 平台 | 文件 |
|---|---|
| Android arm64-v8a | `FlClash-NATIVE-android-arm64-v8a.apk` |
| Windows x64 便携版 | `FlClash-NATIVE-windows-x64.zip` |
| iOS arm64（未签名） | `FlClash-NATIVE-ios-arm64-unsigned.ipa` |
| macOS Apple Silicon | `FlClash-NATIVE-macos-arm64.dmg` |
| macOS Intel | `FlClash-NATIVE-macos-x64.dmg` |

`version.json` 提供五个安装包的大小和 SHA256；更新检查仅接受本仓库对应文件。Android 包名 `cc.llyufeng.flclash.dev`，保留原签名。此前发布的标签及资产不变。
