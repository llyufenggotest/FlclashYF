## FlClashYF VERSION

基于 FlClash Patched **0.9.6** 的功耗与生命周期优化版。用户已确认本轮五端候选验收通过；正式包由相同产品源码重新构建，嵌入本次 Release 更新标识。

### 本次修复与优化
- Android/iOS 强制内存回收不再重复触发两轮 GC，保留内存归还、缓存失效和低内存保护。
- 修复 system/mixed TUN 关闭后 NAT 维护任务未取消，以及启动失败时的栈所有权回滚。
- Snell v4 持续读写复用连接缓冲区，减少分配和 GC；保持协议帧、加密及 nonce 语义，消费后清除明文。
- iOS 成功的常态流量诊断采用有界汇总，保留错误、配置、启动及切换窗口的详细记录；业务错误响应保留逐请求关联。
- iOS 邮箱请求处理与孤儿文件维护解耦，保留通知即时唤醒、漏通知兜底及请求归属、超时保护。
- 连接数卡片改用轻量计数 RPC，不再为数量拉取整张连接列表；iOS 路由与只读重试分类同步补齐。
- 日志、请求及 DNS 页面不可见时停止页面订阅，恢复时重放缓存；隔离迟到结果与停止订阅异常。
- 批量事件有界合并 UI 状态发布，保留事件顺序、历史容量与错误通知。
- 无订阅者且控制台屏蔽时跳过无效日志格式化和发布；修复日志文本中的百分号被误当格式符。

上述开销改善已通过生产路径回归、CPU/分配基准及真实 macOS 原生门禁验证；不承诺固定耗电或温升降幅，实际收益取决于协议、设备与使用场景。

保留全部魔改协议、Blackstone 隔离、自有更新链、iOS RPC/mailbox、完整规则预热与 MRS 回滚、NE 本地加载和低内存保护。**不包含已撤销的备用 DNS 功能。**

**下载**

| 平台 | 文件 |
|---|---|
| Android arm64-v8a | `FlClash-NATIVE-android-arm64-v8a.apk` |
| Windows x64 便携版 | `FlClash-NATIVE-windows-x64.zip` |
| iOS arm64（未签名，需自行侧载签名） | `FlClash-NATIVE-ios-arm64-unsigned.ipa` |
| macOS Apple Silicon | `FlClash-NATIVE-macos-arm64.dmg` |
| macOS Intel | `FlClash-NATIVE-macos-x64.dmg` |

`version.json` 含每个文件的大小与 SHA256，App 内更新检查只接受本仓库的这些文件。

Android 包名 `cc.llyufeng.flclash.dev`，签名保持一致，可覆盖安装并保留数据。此前已发布版本与标签保持不变。
