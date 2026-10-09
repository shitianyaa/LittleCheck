<p align="center">
  <img src="docs/assets/little-check.svg" width="112" height="112" alt="Little Check 应用图标" />
</p>

<h1 align="center">Little Check</h1>

<p align="center">信息流 · Markdown 笔记 · 待办 · AI 翻译与总结</p>
<p align="center">把关注的内容汇成信息流，把值得留下的内容写进笔记。</p>

<p align="center">
  <a href="https://github.com/shitianyaa/LittleCheck/releases/latest"><img src="https://img.shields.io/github/v/release/shitianyaa/LittleCheck?style=flat-square&amp;color=4F7693" alt="最新版本" /></a>
  <a href="https://github.com/shitianyaa/LittleCheck/releases"><img src="https://img.shields.io/github/downloads/shitianyaa/LittleCheck/total?style=flat-square&amp;color=4F7693" alt="Release 下载次数" /></a>
  <a href="https://flutter.dev"><img src="https://img.shields.io/badge/Flutter-3.47.6-4F7693?style=flat-square&amp;logo=flutter&amp;logoColor=white" alt="Flutter 3.47.6" /></a>
  <img src="https://img.shields.io/badge/平台-Android%20%7C%20Windows-4F7693?style=flat-square" alt="Android 与 Windows" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/开源协议-AGPL--3.0-4F7693?style=flat-square" alt="AGPL-3.0 协议" /></a>
</p>

<p align="center">
  <a href="https://github.com/shitianyaa/LittleCheck/releases/latest"><b>下载应用</b></a> ·
  <a href="docs/feed-format.md">制作订阅</a> ·
  <a href="docs/ai-and-notes.md">使用说明</a> ·
  <a href="https://github.com/shitianyaa/LittleCheck/issues">反馈问题</a>
</p>

## 下载

在 [GitHub Releases](https://github.com/shitianyaa/LittleCheck/releases/latest) 选择对应文件：

| 版本 | 文件后缀 | 适合设备 |
| --- | --- | --- |
| Android ARM64 | `android-arm64-v8a.apk` | 多数现代 Android 手机，优先选择 |
| Android ARM32 | `android-armeabi-v7a.apk` | 旧款 32 位 ARM 手机 |
| Android 通用 | `android-universal.apk` | 不确定架构，或使用 x86_64 设备；体积较大 |
| Windows x64 | `windows-x64.zip` | 解压到自选目录，运行 `little_check.exe` |

Windows 为免安装目录包，解压后需保留 EXE 同目录的 DLL 和 Flutter `data` 运行资源文件夹。用户笔记与设置默认存放在系统应用数据目录，因此移动或重新解压程序目录不会丢失数据。Windows 可在「设置 → 外观与存储 → 迁移数据目录」选择一个空文件夹作为新的用户数据目录；应用会先复制并校验，成功后重启生效，旧目录保留为备份。AI Key、设备身份与配对密钥仍保存在系统安全存储，不随自定义目录复制。

三份 Android APK 使用相同的应用 ID、版本号和固定正式签名。此前本机测试签名版本无法直接覆盖，请先导出需要保留的笔记，再换装正式版本。下载文件的 SHA-256 可在 Release 的 `SHA256SUMS.txt` 中核对。

## 能做什么

| 功能 | 使用方式 |
| --- | --- |
| 📰 信息流阅读 | 添加多个 JSON 订阅，按来源、平台筛选，搜索、阅读与保存内容 |
| 📝 Markdown 笔记 | 文件夹、任务清单、回收站、导入导出，支持 16 项快捷格式 |
| 🔗 设备同步 | Windows 开启同步页面，Android 扫码配对，局域网手动双向同步笔记与待办 |
| ✨ 帖内 AI | 翻译与总结，可复制、重试，或保存到预制笔记文件夹 |
| 🎨 外观设置 | 五种配色、亮暗主题、系统字体与 TTF/OTF 字体导入 |

**信息流**：各订阅独立刷新、缓存，失败保留上次内容。按原帖 URL 合并去重，默认保留已接收的近七天，可调整为 14 / 30 / 90 天。仅在进入或恢复应用、手动刷新、切换订阅来源时联网，搜索与平台筛选不触发刷新。

**笔记与待办**：笔记保存在本地 Markdown 文件，待办写在任务清单中。Android 可从文件管理器打开 Markdown，先预览再导入副本；导出文件使用笔记标题命名。卸载应用前请导出需要保留的文件。

**AI 翻译与总结**：自行配置供应商、Key 和模型，支持 Chat Completions、Responses、Messages 三种协议。主模型之外可单独指定翻译、识图模型，未配置时沿用主模型。Key 存入系统安全存储。结果与帖子持久关联，内容或配置变化时保留上次结果并提示；暂停中止请求，重新开始会再次调用模型。

**外观与编辑**：雾蓝、松绿、暖橙、鸢紫、石墨五种配色。默认系统字体，支持导入 TTF/OTF（单文件最多 64 MiB）。环线对号用于应用图标与启动动效，支持系统减弱动效设置。

当前没有账号系统、笔记云同步、后台轮询或锁屏推送。协议、保存与数据行为详见 [使用说明](docs/ai-and-notes.md)。

## 三步开始

1. 下载并安装对应版本，Windows 解压后运行。
2. 在「设置 → 订阅源 → 添加订阅源」填写名称与可访问的 JSON 地址，进入信息流刷新。
3. 如需翻译和总结，在设置中配置自己的 AI 供应商与模型；笔记和待办可直接使用。

## 用 AI 制作自己的订阅

把 [v2 示例](server/feed-v2.example.json)、[JSON Schema](server/feed-v2.schema.json) 和[使用说明](docs/feed-format.md) 发给 AI Agent，复制这句话，并替换其中的内容来源：

> 请按我发给你的 Little Check 模板 `feed-v2.example.json`、格式规范 `feed-v2.schema.json` 和使用说明 `feed-format.md`，把【来源链接或我提供的内容】整理成可订阅的 UTF-8 `feed.json`，保持条目 ID 稳定，保留真实原帖链接和发布时间，完成格式校验，并告诉我如何托管文件及在 App 中添加订阅；缺失的必要信息请列出来让我补充。

将生成的文件托管到手机可访问的 HTTP(S) 地址，再添加为订阅。持续更新需要托管端定期生成文件；模板本身不会自动抓取内容。App 当前不直接订阅 RSS/Atom，需先转换成 JSON。

| 文档 | 内容 |
| --- | --- |
| [订阅模板与字段](docs/feed-format.md) | 5 个顶层字段、9 个帖子字段，校验与接入步骤 |
| [服务器生成与发布](server/README.md) | JSON 校验、原子发布、生成器与 RSS 来源 |
| [GitHub Pages 镜像](docs/github-feed-publishing.md) | 通用部署教程与可选工作流触发 |
| [构建与发布](docs/releasing.md) | 正式签名、GitHub 自动构建与版本发布 |

## 开发

Flutter **3.47.6** / Dart **3.13.5**，依赖锁定于 `pubspec.lock`。Windows 构建需安装 Visual Studio 的 C++ 桌面开发工具链。

```sh
flutter pub get
flutter test
flutter analyze
flutter build apk --release --target-platform android-arm64
```

服务端检查需先安装 [server/requirements.txt](server/requirements.txt) 中的依赖：

```sh
python3 -m pip install -r server/requirements.txt
python3 -B -m unittest discover -s server -v
```

推送版本标签时，GitHub 在同一工作流内完成检查、Android 三份 APK 与 Windows ZIP 构建，再发布 Release 和校验文件。普通 main 推送不重复触发；PR 与手动检查保留。签名配置见 [发布说明](docs/releasing.md)。未配置正式签名的本机测试构建使用测试签名。

## 组件与来源

- [flutter_markdown_plus](https://github.com/flutter-markdown-plus/flutter-markdown-plus) / [markdown](https://github.com/dart-lang/markdown)：GFM 渲染、解析与任务定位。
- [Flutter packages](https://github.com/flutter/packages)：path_provider、file_selector、url_launcher，负责数据目录、文件选择和来源链接。
- [share_plus](https://github.com/fluttercommunity/plus_plugins)：Android 系统分享与导出。
- Dart HttpClient、Python 标准库与 crypto：网络、原子发布与缓存隔离；Flutter FontLoader 加载自定义字体。
- [ai-toolbox](https://github.com/coulsontl/ai-toolbox)：102 条模型预设数据，来源与 AGPL-3.0 许可见 [assets/ai/NOTICE.txt](assets/ai/NOTICE.txt)。预设仅供参考，不保证兼容所有供应商。

旧字体及授权文件保留在 `assets/fonts` 作为测试资源，不再打包进 APK。

## 开源协议

本项目基于 [GNU Affero General Public License v3.0 (AGPL-3.0)](LICENSE) 开源。

Copyright (C) 2026 shitianyaa

- 任何基于本项目修改、衍生或分发的版本（包括通过网络提供服务），均必须以 AGPL-3.0 协议完全开源所有源代码。
- 必须完整保留原作者署名及版权声明。
