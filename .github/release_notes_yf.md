## FlClashYF VERSION

基于 FlClash Patched **0.9.6** 融合，保留 FlClashYF 自有核心、全部魔改协议及已验收的 iOS 配置切换保护。

### 本次更新
- 修复合并配置请求时强制应用标记丢失，保留串行调度、取消与失败回滚。
- 同步 Android/iOS 启停协调改进，并补充重启停止屏障的请求所有权与超时行为测试。
- 优化测速并发和批量刷新；异步排序使用独立快照，业务连接的前置代理逻辑不变。
- 增加订阅流量、核心版本及进程内存详情显示，优化节点分组、规则详情、遥控器操作和托盘布局。
- 补齐 App 对核心内置 CA 的信任与五端资源打包，继续严格验证证书及域名。

自有 mihomo/sing 协议栈保持本轮已验收版本，不代表升级到上游的新核心。保留 Blackstone 私有字段与严格后缀隔离、iOS RPC/mailbox、完整规则预热与 MRS 回滚、NE 本地加载和低内存保护。**不包含已撤销的备用 DNS 功能。**

自动测试与构建通过不等同于新版本五端真机验收；未签名 iOS 包需自行侧载签名。

**下载**

| 平台 | 文件 |
|---|---|
| Android arm64-v8a | `FlClash-NATIVE-android-arm64-v8a.apk` |
| Windows x64 便携版 | `FlClash-NATIVE-windows-x64.zip` |
| iOS arm64（未签名，需自行侧载签名） | `FlClash-NATIVE-ios-arm64-unsigned.ipa` |
| macOS Apple Silicon | `FlClash-NATIVE-macos-arm64.dmg` |
| macOS Intel | `FlClash-NATIVE-macos-x64.dmg` |

`version.json` 含每个文件的大小与 SHA256，App 内更新检查只接受本仓库的这些文件。

Android 包名 `cc.llyufeng.flclash.dev`，签名与此前版本一致，可覆盖安装并保留数据。
