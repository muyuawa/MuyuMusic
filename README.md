# Muyu Cloud Music · 暮雨音乐

这是 **1.3.1 的 iOS 6 兼容分支 `codex/ios6`**，基于 `0c01844`，面向越狱的 iPod touch 4 等 **iOS 6.0+ / 32 位 ARMv7** 设备。应用采用 Objective-C / UIKit，直接访问网易云，无需部署 API、Node.js 或 VPS；本地曲库与主题可离线使用。

版本 **1.3.1（构建 17，iOS 6）** 保留自定义音源、pdone 仓库订阅、加速下载、洛雪脚本、HTTPS 开关和错误详情。应用内界面统一扁平样式，包含搜索、分类、底部导航、开关、列表操作和弹窗。扫码登录使用本地 C 二维码库。iOS 6 的在线 MP3/AAC/M4A 等系统解码格式先下载完整再播放；FLAC 继续增量解码，iOS 7 的原有渐进式加载仍保留。

本分支仅本地交付测试，未推送 GitHub。编译及主机测试不能代替 iOS 6 真机验收，详见 [兼容说明](docs/COMPATIBILITY.md) 和 [分支记录](docs/releases/1.3.1-ios6.md)。

## 使用

1. 使用本地构建的 `dist/MuyuMusic-1.3.1-ios6-armv7.ipa`，按 [安装说明](docs/INSTALL.md) 安装。
2. 在音乐库 → 账号与扫码登录，使用另一部手机的网易云音乐扫码并确认。登录前也可搜索和浏览公共内容；实际播放由平台权限决定。
3. 发现页浏览推荐歌单或登录后查看每日推荐；搜索支持歌曲、歌手、专辑与歌单。歌曲右侧按钮可加入队列、收藏、添加本地歌单、修改网易云喜欢状态或浏览歌手/专辑。
4. 用 iTunes 文件共享向“暮雨音乐”添加 MP3、AAC/M4A、ALAC、FLAC、WAV、AIFF。可以添加子目录；同名 `.lrc` 与音乐放在一起。回到应用自动扫描，也可手动扫描。
5. 底部播放器进入正在播放，切换封面/歌词、点击歌词定位、调整进度、循环、随机和编辑队列。设置可切换深浅模式、开启跟随封面配色、自定义 HEX 主色和在线音质。
6. 歌单中个别歌曲暂无详情时，显示已返回的真实歌曲与缺失数量，可重试；不会使整张歌单无法打开。
7. FLAC 输出采用有上限的 PCM 缓冲（44.1 kHz 双声道约 1.5 秒），合并短音频帧并在耗尽后补足再恢复。
8. 在线 FLAC 预缓存约 5 秒音频后起播。设置可选择歌曲缓存上限（默认 256 MB，可关闭或选择 64 MB～1 GB）、查看占用并清理；清理保护当前播放文件。缓存重播仍需联网确认账号权限。

设置 → 音源，可保留网易云直连，或导入支持网易云 `wy` 的洛雪 `.js`、添加自定义 API。默认开启“仅允许 HTTPS”；长青等返回 HTTP 地址的音源需关闭此选项后重试。首次导入不会自动启用，脚本和 API 不获得网易云登录凭据。详见 [音源说明](docs/CUSTOM-SOURCES.md)。

“仓库音源”动态显示 [pdone/lx-music-source](https://github.com/pdone/lx-music-source) 的 `latest.js`。导入后可手动同步，也可在回到前台时每天自动检查。下载方式可选择 GitHub 官方接口、`ghproxy.net` 及仓库列出的备用加速站点；更新先校验，失败保留旧版。同步不自动导入其他源或切换当前来源。

“无损优先”是请求偏好；音质标识来自实际音源/解码信息。网易云直连中没有完整播放权限的试听链接会被拒绝。自定义源由用户配置，其代码许可、服务权限和音乐内容授权需分别确认。

## 构建

实测环境：Intel macOS、Apple clang 21.0.0、ld-classic、iOS 7.1 SDK、CMake 3.31.12、Python 3。无需完整 Xcode；需要可生成 ARMv7 的 clang/ld-classic 和 CMake。Apple Silicon 可运行对应 Intel 工具时再尝试，尚未验证。

```sh
python3 scripts/bootstrap.py
python3 scripts/draw-assets.py
bash scripts/build-deps.sh
bash scripts/build.sh
```

已有合法 SDK 可设置 `IOS_SDK=/absolute/path/iPhoneOS7.1.sdk`。`bootstrap.py --no-sdk` 只准备开源依赖与构建工具。构建输入均校验 SHA-256，依赖发行归档下载到被忽略的 `vendor/archives/`；SDK 不随源码再分发。CMake 可通过环境变量 `CMAKE` 指定路径。

仓库及源码包保留程序、应用资源、原始图标素材、构建脚本、测试、许可证与必要文档。SDK、依赖缓存、构建产物、设备日志、截图和设计草稿由 `.gitignore` 排除。IPA 与校验文件通过 Releases 提供。

提供 Theos `Makefile`，架构 `armv7`、SDK 7.1、最低系统 6.0。准备 `.build/deps` 后可在已配置的 Theos 环境尝试 `make package`；**本次实际执行并验证的是 `scripts/build.sh`，Theos 分支未实测**。最低版本 6.0 来自实际 Mach-O 与 Info.plist 检查；尚待 iOS 6 真机测试。

构建脚本逐个编译全部源文件，静态链接 libFLAC/libcurl/Mbed TLS，使用 SHA-1 ad-hoc 签名，再检查 Mach-O、系统依赖、entitlements、CA、许可证、文件共享与后台音频配置。生成文件位于 `dist/`，文件名包含 `ios6`，不会覆盖原版 IPA。依赖首次切换分支时会按目标重新构建；包检查会逐个检查静态库成员的系统版本。

## 必要测试

```sh
python3 scripts/bootstrap.py --no-sdk # 新克隆先准备已锁定的测试依赖
bash scripts/test.sh          # 本机确定性测试：协议/曲库/播放数据通路/主题
bash scripts/test.sh --tls    # 另测实际捆绑 TLS 后端和一次真实搜索；首次会编译主机依赖
bash tests/source_repository_live.sh ghproxy.net # 可选：真实仓库目录/加速下载/初始化，不测试音乐播放
```

完整公共接口探测保留为可选的 `tests/network_live.sh`，默认不重复执行。本分支新增编码、二维码解码回读、音频起播时机测试；`bash tests/ios6_compile.sh` 检查全部源文件的 iOS 6 API 可用性。真机验收范围见 [分支记录](docs/releases/1.3.1-ios6.md)。

## 代码导航

- `Sources/Network`：HTTPS、加密接口、Keychain 会话、登录和权限处理。
- `Sources/Library`：串行 SQLite、文件扫描、受限元数据/封面提取、LRC。
- `Sources/Playback`：统一队列、AVPlayer、渐进式资源加载、libFLAC/AudioQueue。
- `Sources/UI`：原生发现/搜索/音乐库/详情/播放/账号/设置、主题、封面缓存。
- `scripts`：可执行构建、校验与必要测试入口。

模块边界见 [接口契约](docs/INTERFACES.md)。具体实现与限制见 [网络](docs/NETWORK.md)、[曲库](docs/LIBRARY.md)、[播放](docs/PLAYBACK.md)。[依赖与许可证](docs/DEPENDENCIES.md) 包含第三方来源；许可证原文同时附在 IPA 内。
