Little Check 首个公开版本，提供信息流阅读、本地 Markdown 笔记与待办，以及帖内 AI 翻译和总结。

- **Android**：多数手机选择 `android-arm64-v8a.apk`；旧款 32 位 ARM 手机选择 `android-armeabi-v7a.apk`。不确定架构或使用 x86_64 设备时选择 `android-universal.apk`，包含 ARM32、ARM64、x86_64，体积较大。三份 APK 使用同一正式签名。此前本机测试签名版本无法直接覆盖，请先导出需要保留的笔记，再卸载旧版本并安装；后续正式版本保持同一签名。
- **Windows x64**：下载 ZIP，解压到自己选择的目录，运行 `little_check.exe`。保留同目录 DLL 和 `data` 文件夹；运行库已随包附带。笔记和设置保存在系统应用数据目录，移动程序目录不会迁移数据。
- `SHA256SUMS.txt` 提供下载文件的 SHA-256 校验值。

支持多个 JSON 订阅、按来源/平台筛选、七天历史合并、失败保留缓存；笔记支持文件夹、回收站、导入导出和字体导入。AI 模型需要自行配置，支持 Chat Completions、Responses、Messages。

[自定义订阅与 AI 一句话上手说明](https://github.com/shitianyaa/LittleCheck/blob/main/docs/feed-format.md) · [模板示例](https://github.com/shitianyaa/LittleCheck/blob/main/server/feed-v2.example.json) · [JSON Schema](https://github.com/shitianyaa/LittleCheck/blob/main/server/feed-v2.schema.json)

无账号系统、笔记云同步、后台轮询或锁屏推送。Windows 为免安装目录包，尚未提供安装器或单文件 EXE；本次未验证干净 Windows 机器上的完整交互及所有供应商的真实 AI 调用。
