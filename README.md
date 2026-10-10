<div>

[**简体中文**](README_zh_CN.md)

</div>

# FlClashYF

[![Downloads](https://img.shields.io/github/downloads/llyufenggotest/FlclashYF/total?style=flat-square&logo=github)](https://github.com/llyufenggotest/FlclashYF/releases/)[![Last Version](https://img.shields.io/github/release/llyufenggotest/FlclashYF/all.svg?style=flat-square)](https://github.com/llyufenggotest/FlclashYF/releases/)[![License](https://img.shields.io/github/license/llyufenggotest/FlclashYF?style=flat-square)](LICENSE)

A fork of [FlClash](https://github.com/chen08209/FlClash), with verified custom protocol integrations and lifecycle improvements.

> [!CAUTION]
> 如果您是中华人民共和国公民或者长期居住在中华人民共和国境内，请在使用前仔细阅读并理解 [免责声明](./README_zh_CN.md#免责声明) 中的内容。下载、安装或使用本项目即表示您同意免责声明中的条款，并承担由此产生的全部责任。

## Features

- Support iOS platform (requires an Apple Developer account to build)
- Verified custom protocol integrations (Oix, X365, and private protocols)
- Lifecycle and memory management improvements
- Energy efficiency optimizations (improved Android Doze, unified UI timer suspend)
- UI optimizations (proxy selection, log and connection filtering/sorting)
- Compressed geo resources for smaller package size
- Self-hosted update checks with package integrity verification

## Download

**Latest release:** [v0.9.4-yf.1](https://github.com/llyufenggotest/FlclashYF/releases/latest)

<a href="https://github.com/llyufenggotest/FlclashYF/releases"><img alt="Get it on GitHub" src="snapshots/get-it-on-github.svg" width="200px"/></a>

| Platform | File |
|----------|------|
| Android arm64-v8a | `FlClash-0.9.4-android-arm64-v8a.apk` |
| Windows x64 (portable) | `FlClash-0.9.4-windows-x64.zip` |
| iOS arm64 (unsigned, requires self-signing) | `FlClash-0.9.4-ios-arm64-unsigned.ipa` |
| macOS Apple Silicon | `FlClash-0.9.4-macos-arm64.dmg` |
| macOS Intel | `FlClash-0.9.4-macos-x64.dmg` |

Android package name: `cc.llyufeng.flclash.dev`. Signing is consistent with previous versions, allowing installation over existing versions with data retention.

## Use

### Linux

⚠️ Make sure to install the following dependencies before using them

   ```bash
    sudo apt-get install libayatana-appindicator3-dev
   ```

### Android

Support the following actions

   ```bash
    cc.llyufeng.flclash.dev.action.START
    
    cc.llyufeng.flclash.dev.action.STOP
    
    cc.llyufeng.flclash.dev.action.TOGGLE
   ```

## Build

1. Update submodules
   ```bash
   git submodule update --init --recursive
   ```

2. Install `Flutter` and `Golang` environment

3. Build Application

    - android

        1. Install `Android SDK`, `Android NDK`

        2. Set `ANDROID_NDK` environment variable

        3. Run build script

           ```bash
           dart setup.dart android
           ```

    - windows

        1. Requires a Windows client

        2. Install `GCC`, `Inno Setup`

        3. Run build script

           ```bash
           dart setup.dart windows
           ```

    - linux

        1. Requires a Linux client

        2. Dependencies are auto-installed by setup script, or manually:
           ```bash
           sudo apt-get install -y libayatana-appindicator3-dev
           ```

        3. Run build script

           ```bash
           dart setup.dart linux
           ```

    - macOS

        1. Requires a macOS client

        2. Run build script

           ```bash
           dart setup.dart macos
           ```

    - iOS

        1. Requires a macOS client

        2. Configure Apple Developer capabilities, App Group and provisioning profiles for the app bundle and Network Extension bundle

        3. Run build script

           ```bash
           dart setup.dart ios --ios-bundle-id com.example.flclash
           ```

## Acknowledgements

This project is based on:
- [FlClash](https://github.com/chen08209/FlClash) by chen08209
- [FlClash-Patched](https://github.com/chenx-dust/FlClash-Patched) by chenx-dust
- [mihomo](https://github.com/MetaCubeX/mihomo)

## Disclaimer

This software is an open-source project maintained personally, building upon FlClash with custom protocol integrations and improvements. It is designed to provide easy-to-use and highly customizable network layer-7 proxy and routing functionality. Users must comply with the relevant laws and regulations of their jurisdiction when using this software, and must not use it for any illegal or criminal activities. We reserve the right to refuse to provide technical support for any use involving or potentially involving cybercrime or circumvention of regulatory systems, and we do not assume any legal liability, economic losses, or other consequences arising from the use of this software.

## License

[GPL-3.0](LICENSE)
