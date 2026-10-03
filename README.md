# Little Check

Android 信息流与本地 Markdown 笔记，待办保存在 Markdown 的任务清单中。

## 下载

[GitHub Releases](https://github.com/shitianyaa/LittleCheck/releases/latest)：Android 多数手机下载 ARM64（arm64-v8a），旧款 32 位 ARM 手机下载 ARM32（armeabi-v7a）；不确定架构或使用 x86_64 设备时下载通用 APK，Windows x64 下载免安装 ZIP，解压到自选目录后运行 `little_check.exe`，保留同目录 DLL 与 data。Windows 的笔记和设置仍保存在系统应用数据目录。

公开 APK 使用固定正式签名；之前本机测试签名版本无法直接覆盖，请先导出笔记再换装。后续正式版本保持同一签名。各下载文件的 SHA-256 位于 Release 的 `SHA256SUMS.txt`。

## 使用

AI 结果按帖子持久关联。原帖标题/正文或模型配置变化时，重新进入仍显示上次结果并提示变化；手动重新生成成功后才更新结果。处理时支持暂停并显示用时，暂停会关闭当前请求，重新开始需再次调用模型，已有结果保留。成功调用的总用时随结果保存。

历史合并优先使用原帖 URL；不同 URL 即使复用同一个 ID 也分别保留，同一 URL 更新一条。七天保留的是已接收到的帖子，无法恢复旧版本已经覆盖或从未接收的条目。

客户端支持多个 JSON 订阅源，分别刷新与缓存，合并后按原帖 URL 去重。平台标签自动读取条目 platform 字段，缺失归到其他；支持订阅来源与平台组合筛选、左右滑动、保留滚动位置、返回顶部。刷新完成后短暂显示生成时间，单个订阅失败保留原缓存。

信息流仅在进入应用、手动下拉/点击刷新、切换订阅来源时请求更新；平台切换、搜索、返回设置不刷新。带图帖子显示图片标记。选择框统一使用外置标签和底部选择列表。

信息流按订阅分别合并历史，默认保留最近七天，设置可改为 14 / 30 / 90 天。同 ID 或同 URL 更新原条目；刷新失败保留缓存，未访问期间的帖子需要订阅服务端自行保留，客户端无法补回从未收到的条目。

AI 只提供翻译与总结：标题下点击翻译，右下角点击总结，结果显示在帖子底部，可复制、重试或存入「AI 翻译 / AI 总结」文件夹。GitHub 仓库可拉取并缓存 README，AI 调用时自动补充。设置集中管理独立提示词、主模型、可选翻译/识图模型及默认思考参数。支持 Chat Completions、Responses、Messages，HTTP/HTTPS、多供应商、多 Key、多模型、拉取列表、手填 ID 与别名。模型预设来自 ai-toolbox，应用预设保留请求 ID；密钥存入系统安全存储。旧聊天文件保留，阅读页不再提供聊天或联网查询入口。

笔记支持单层文件夹和回收站，分享/导出以笔记标题命名。Android 支持从文件管理器选择应用打开 Markdown，先预览再导入副本。信息流与笔记图片共用磁盘缓存。详细约定见 [docs/ai-and-notes.md](docs/ai-and-notes.md)，通用订阅格式与模板见 [docs/feed-format.md](docs/feed-format.md)。

无锁屏推送、后台轮询、账号或笔记云同步。笔记存在应用私有目录，卸载前通过导出保留文件。VPS 使用现有静态网站，Hermes 每小时生成 JSON，发布器校验成功后替换文件，失败保留旧内容；成功后主动触发 GitHub Pages 镜像更新，GitHub 原定时任务保留兜底。服务器生成与发布接入见 [server/README.md](server/README.md)。

## 制作自己的订阅

下载 [v2 示例](server/feed-v2.example.json)、[JSON Schema](server/feed-v2.schema.json) 和[使用说明](docs/feed-format.md)，发给 AI Agent，并使用说明里的「一句话提示词」生成自己的 `feed.json`。将文件托管到手机可访问的 HTTP(S) 地址，在「设置 → 订阅源 → 添加订阅源」填写名称和 JSON 地址即可。持续更新需要托管端定期生成文件；字段含义、校验与图片约定均见使用说明。

## 外观与编辑

设置支持雾蓝、松绿、暖橙、鸢紫、石墨五种配色，并分别适配亮暗模式。默认使用系统字体，APK 不内置中文字体。在「设置 → 配色与字体 → 导入字体」选择 TTF / OTF 文件（单个最多 64 MiB），预览后点击保存应用；文件复制到应用私有目录，重启后继续加载，也可切回系统字体。重新导入可替换当前自定义字体。旧版文楷/黑体选择按系统字体处理；自定义文件丢失或损坏时明确提示，临时回退系统字体，原配置保留以便重新导入。暂不支持 TTC 字体合集。

笔记底部保留常用工具，点击「更多格式」打开 16 项格式面板：三级标题、粗体、斜体、删除线、无序/有序列表、待办、引用、链接、图片、行内代码、代码块、分隔线、表格。空光标时插入并选中占位文字，直接输入即可替换；选中文字时保留原内容，块格式与前后段落分隔。

环线对号标识用于桌面图标、Android 12+ 原生启动动画和顶部一次性动画，不人为增加启动等待。正常保留精致、流畅的短时动效，系统减少动态效果仅作无障碍适配；系统启动动画由 Android 控制。Android 7–11 使用静态原生启动页。

## 开发环境

Flutter 3.47.6 / Dart 3.13.5，依赖版本锁定于 pubspec.lock。

```sh
flutter pub get
flutter test
flutter analyze
flutter build apk --release --target-platform android-arm64
python3 -m unittest discover -s server -v
```

当前 Windows 开发机 SDK 位于 .tools/flutter。Flutter 原生构建工具对含空格的 SDK 路径处理异常，建立了 D:\Project\LittleCheckSDK 目录联接，使用其 bin/flutter.bat。Pub 缓存设置为项目内 .tools/pub-cache，避免 Kotlin 增量编译跨 C/D 盘路径失败，Gradle 缓存为 .tools/gradle。工具和缓存不属于源码。

```powershell
$env:PUB_CACHE = 'D:\Project\Little Check\.tools\pub-cache'
& 'D:\Project\LittleCheckSDK\bin\flutter.bat' test --no-pub
& 'D:\Project\LittleCheckSDK\bin\flutter.bat' analyze --no-pub
```

Windows x64 已在本机构建成功。GitHub 工作流使用 Flutter 3.47.6 检查代码，并在版本标签推送后构建 Android ARM64 / ARM32 / 通用三份 APK、完整 Windows x64 ZIP 与 SHA-256 文件，再创建 Release；签名配置和发布步骤见 [docs/releasing.md](docs/releasing.md)。未配置签名的本地测试构建仍使用测试签名，CI 发布必须使用固定正式签名。真机导入、分享、帧率及干净 Windows 机器上的完整使用仍待验证。

## 复用组件

- [flutter_markdown_plus](https://github.com/flutter-markdown-plus/flutter-markdown-plus) 与 [markdown](https://github.com/dart-lang/markdown)：GFM 渲染和解析，按源位置修改任务。
- [Flutter packages](https://github.com/flutter/packages)：path_provider、file_selector、url_launcher，负责数据目录、文件选择和来源链接。
- [share_plus](https://github.com/fluttercommunity/plus_plugins)：Android 导出到系统分享。
- Dart HttpClient、Python 标准库：网络与原子发布；crypto 用于按 URL 隔离缓存。
- Flutter FontLoader 与现有 file_selector：动态加载用户选择的字体，不新增依赖。assets/fonts 的旧字体及授权文件保留为测试资源，不再打包进 APK。
- [ai-toolbox](https://github.com/coulsontl/ai-toolbox)：内置 102 条模型预设数据，原始数据及 AGPL-3.0 许可位于 assets/ai，来源与版本见 NOTICE.txt；配置适配代码独立实现。第三方预设属于参考配置，不保证兼容每个供应商。

未引入额外状态管理、数据库或动画框架。亮暗主题使用中性色、低饱和蓝和短标签过渡。

关键代码：lib/feed.dart、lib/storage.dart、lib/tasks.dart、lib/markdown_view.dart；界面位于 lib/app.dart、lib/feed_view.dart、lib/note_view.dart。发布器为 server/publish_feed.py。
