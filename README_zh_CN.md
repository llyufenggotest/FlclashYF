<div>

[**English**](README.md)

</div>

# FlClashYF

[![Downloads](https://img.shields.io/github/downloads/llyufenggotest/FlclashYF/total?style=flat-square&logo=github)](https://github.com/llyufenggotest/FlclashYF/releases/)[![Last Version](https://img.shields.io/github/release/llyufenggotest/FlclashYF/all.svg?style=flat-square)](https://github.com/llyufenggotest/FlclashYF/releases/)[![License](https://img.shields.io/github/license/llyufenggotest/FlclashYF?style=flat-square)](LICENSE)

[FlClash](https://github.com/chen08209/FlClash) 的分支版本，集成验证后的自有协议并改进生命周期管理。

## 免责声明

> [!CAUTION]
> 如果您是中华人民共和国公民或者长期居住在中华人民共和国境内，请在使用前仔细阅读并理解以下内容。下载、安装或使用本项目即表示您同意以下条款，并承担由此产生的全部责任。

本软件是个人维护的、在 FlClash 基础上补充完善相关功能的开源软件，目的在于提供易用且高度自定义的网络七层代理与分流功能。用户在使用本软件时必须遵守中华人民共和国的相关法律法规，不得利用本软件从事任何违法犯罪活动。我们有权拒绝为任何涉及或可能涉及网络犯罪或规避监管制度的用途提供技术支持，不对因使用本软件而导致的任何法律责任、经济损失或其他后果承担任何责任。

## 特性

- 支持 iOS 平台（需使用 Apple 开发者账号自行编译安装）
- 已验证的自有协议集成（Oix、X365 及私有协议）
- 生命周期和内存管理改进
- 能效优化（优化 Android Doze 支持、统一 UI 定时器休眠）
- UI 优化（代理选择界面、日志与连接筛选排序）
- 地理数据库压缩以减小安装包体积
- 自托管更新检查与包完整性校验

## 下载

**最新版本：** [v0.9.4-yf.1](https://github.com/llyufenggotest/FlclashYF/releases/latest)

<a href="https://github.com/llyufenggotest/FlclashYF/releases"><img alt="Get it on GitHub" src="snapshots/get-it-on-github.svg" width="200px"/></a>

| 平台 | 文件 |
|------|------|
| Android arm64-v8a | `FlClash-0.9.4-android-arm64-v8a.apk` |
| Windows x64 便携版 | `FlClash-0.9.4-windows-x64.zip` |
| iOS arm64（未签名，需自行侧载签名） | `FlClash-0.9.4-ios-arm64-unsigned.ipa` |
| macOS Apple Silicon | `FlClash-0.9.4-macos-arm64.dmg` |
| macOS Intel | `FlClash-0.9.4-macos-x64.dmg` |

Android 包名 `cc.llyufeng.flclash.dev`，签名与此前版本一致，可覆盖安装并保留数据。

## 使用

### Linux

⚠️ 使用前请确保安装以下依赖

   ```bash
    sudo apt-get install libayatana-appindicator3-dev
   ```

### Android

支持下列操作

   ```bash
    cc.llyufeng.flclash.dev.action.START
    
    cc.llyufeng.flclash.dev.action.STOP
    
    cc.llyufeng.flclash.dev.action.TOGGLE
   ```

## 构建

1. 更新 submodules
   ```bash
   git submodule update --init --recursive
   ```

2. 安装 `Flutter` 以及 `Golang` 环境

3. 构建应用

    - android

        1. 安装  `Android SDK` ,  `Android NDK`

        2. 设置 `ANDROID_NDK` 环境变量

        3. 运行构建脚本

           ```bash
           dart setup.dart android
           ```

    - windows

        1. 你需要一个windows客户端

        2. 安装 `GCC`，`Inno Setup`

        3. 运行构建脚本

           ```bash
           dart setup.dart windows
           ```

    - linux

        1. 你需要一个linux客户端

        2. 依赖会由 setup 脚本自动安装，也可以手动安装：
           ```bash
           sudo apt-get install -y libayatana-appindicator3-dev
           ```

        3. 运行构建脚本

           ```bash
           dart setup.dart linux
           ```

    - macOS

        1. 你需要一个macOS客户端

        2. 运行构建脚本

           ```bash
           dart setup.dart macos
           ```

    - iOS

        1. 你需要一个macOS客户端

        2. 为 App Bundle 和 Network Extension Bundle 配置 Apple Developer capabilities、App Group 以及描述文件

        3. 运行构建脚本

           ```bash
           dart setup.dart ios --ios-bundle-id com.example.flclash
           ```

## 致谢

本项目基于：
- [FlClash](https://github.com/chen08209/FlClash) by chen08209
- [FlClash-Patched](https://github.com/chenx-dust/FlClash-Patched) by chenx-dust
- [mihomo](https://github.com/MetaCubeX/mihomo)

## 许可证

[GPL-3.0](LICENSE)
