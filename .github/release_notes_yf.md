## FlClashYF VERSION

基于上游 FlClash 0.9.5 融合，保留 FlClashYF 全部自有协议与生命周期修复。

保留 Blackstone 身份字段、精确密码后缀、设备下划线字段与旧配置别名；升级上游按需连接、服务状态与 iOS Widget。五端构建及自动测试不等同于五端真机验收。

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
