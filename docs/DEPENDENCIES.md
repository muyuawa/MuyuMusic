# 依赖、许可证与构建来源

应用自身代码采用根目录 MIT License。没有复制 HyPlayer 或 YesPlayMusic 的 UI/播放器源代码；仅参考其接口分层与功能组织。网易云 API 是未公开保证稳定的客户端接口，平台可随时变更。

| 输入 | 版本 / 来源 | 许可证 / 用途 |
|---|---|---|
| libFLAC | [Xiph 1.5.0](https://github.com/xiph/flac/releases/tag/1.5.0) | Xiph BSD；只链接 C 编解码库，不打包 GPL 命令行程序 |
| libcurl | [curl 8.23.0](https://curl.se/download.html) | curl license；HTTP(S)，异步工作线程 |
| Mbed TLS | [3.6.7](https://github.com/Mbed-TLS/mbedtls/releases/tag/mbedtls-3.6.7) | Apache 2.0；独立 TLS 1.2+ 与证书校验 |
| Mozilla CA bundle | [curl CA extract](https://curl.se/docs/caextract.html) | MPL 2.0；Resources/cacert.pem 原样提供 |
| ldid | [Procursus v2.1.5-procursus7](https://github.com/ProcursusTeam/ldid/releases/tag/v2.1.5-procursus7) | GPLv3；构建工具，不随 IPA 链接或打包 |
| Apple iOS SDK | 7.1，归档提交 `189a487850e3351cf624b5cef9c8317138c89b05` | Apple 专有；仅本机编译，不包含在交付源码或 IPA 中 |
| clang / ld-classic | Apple Command Line Tools，实测 clang 21.0.0 / ld64-957.1 | 系统构建工具；不随应用分发 |
| SQLite / 系统框架 | 目标系统自带 | 仅动态链接，无现代第三方 UI 依赖 |
| QuickJS | [2026-06-04](https://bellard.org/quickjs/) | MIT；嵌入 C 解释器，独立 LX 兼容层使用，不包含进程/文件系统模块 |
| Nayuki QR Code generator | [v1.8.0](https://github.com/nayuki/QR-Code-generator/tree/720f62bddb7226106071d4728c292cb1df519ceb/c) | MIT；在 iOS 6 本地生成登录二维码，原样源码位于 Sources/Core/qrcodegen.c/.h |
| LX Music 接口文档 | [公开脚本接口](https://lxmusic.toside.cn/desktop/custom-source) | 文档 MIT；许可正文随包。兼容层独立实现，没有复制洛雪应用源码 |

源码仓库与压缩包保留项目代码、构建脚本和许可证。开源库原始发行源码归档由 `scripts/bootstrap.py` 下载到被忽略的 `vendor/archives/`，SHA-256 同时锁定于该脚本；`.deps/` 中的解压源码、SDK 与工具仅用于本机构建。许可证原文位于 `vendor/licenses`，同时拷贝到 IPA 的 `MuyuMusic.app/Licenses`。

QuickJS 归档 SHA-256：`b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`。构建时仅禁用单队列运行不需要的共享内存 Atomics（其等待实现依赖 iOS 6/7 没有的 `clock_gettime`），保留栈和执行中断检查。原始源码归档不修改，构建补丁见 `scripts/build-quickjs.sh`。没有依赖系统 JavaScriptCore 的现代语法支持，也没有捆绑第三方音源脚本或用户 Token。

洛雪程序自身标注 Apache-2.0，并在 README 附有补充条款。本项目只实现文档接口兼容；这不表示把洛雪应用源码改标成 MIT，也不表示获得洛雪官方认可。第三方脚本需独立核对其许可证；软件许可不授予音乐内容或服务访问授权。

Mbed TLS 使用其正式支持的 `MBEDTLS_PLATFORM_MS_TIME_ALT` 钩子。iOS 6/7 没有 `clock_gettime`，应用以 `mach_absolute_time` 实现单调毫秒计时；不禁用 TLS 时间检查或主机名验证。libcurl 源码未做本地安全逻辑修改。

CA bundle SHA-256：`796f1389bfea13c0ed78f663b765baaff54a508e5483786bd6ece73c5e3e3cbe`。可从官方 CA extract 更新该文件后重新构建。设备日期必须正确，证书错误会明确返回给用户。

项目参考：[HyPlayer](https://github.com/HyPlayer/HyPlayer)、[YesPlayMusic](https://github.com/qier222/YesPlayMusic)、[Legacy iOS Kit](https://github.com/LukeZGD/Legacy-iOS-Kit)。这些参考项目不是运行时依赖。

本分支所有 ARMv7 依赖以 `armv7-apple-ios6.0` 重新编译。QR 库是唯一直接纳入项目的新增 C 依赖，原始文件 SHA-256：

- `qrcodegen.c`: `300eff07ee25baaa7578f20284411638154716379437391e7e689c0e6ce81403`
- `qrcodegen.h`: `e82df4bff37d18b5863b9e7486fe6bda1b6cda8c3b9ecebfec473907265cb589`

其完整许可位于 `vendor/licenses/Nayuki-QR-Code-generator-MIT.txt`，同时打包到 IPA。
