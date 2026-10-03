# 构建与发布

工作流：[release.yml](../.github/workflows/release.yml)。固定 Flutter 3.47.6，与当前 `pubspec.lock` 配套。

- 向 `main` 提 PR 或手动运行：执行测试、格式、静态分析与服务端测试。普通 `main` 推送不自动运行，避免合入后紧接着发版本标签时重复检查。
- 推送与 `pubspec.yaml` 版本一致的 `v<版本>` 标签：先检查，再并行构建 Android 三份 APK（ARM64、ARM32、通用）、Windows x64 ZIP，全部成功后发布 GitHub Release 和 SHA-256 校验文件。三份 APK 使用同一签名；Actions 中转产物保留一天，Release 提供正式下载。
- CI Android 构建必须有固定签名，缺少签名配置直接失败。三份 APK 使用相同的应用 ID、版本号与签名，可在设备支持的架构包之间切换。Windows ZIP 包含 EXE、DLL、data 和 Visual C++ 运行库；用户自行选择解压目录，数据仍存在系统应用数据目录。

## Android 签名

在仓库 Actions secrets 中配置 `ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。密钥库仅在构建任务中恢复，权限 600，任务结束清理，不上传为构建产物。

本机构建时以进程环境变量提供 `ANDROID_KEYSTORE_PATH`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。未配置时本地测试仍沿用旧测试签名；CI 禁止此回退。保留正式签名密钥及其密码的安全备份，后续版本使用同一签名；从旧测试签名换到正式签名需要先导出笔记再换装。

## 发布步骤

1. 更新 `pubspec.yaml` 版本和 `docs/release-notes.md`；检查变更、完成测试后合入 `main`。
2. 为该提交创建标签，例如 `git tag v0.1.0`，再推送 `git push origin v0.1.0`。
3. 等待工作流成功，检查 Release 的 APK、ZIP 与校验文件；未完成构建不得手工伪造成功 Release。

标签创建、推送和公开发布需要用户本次明确授权。不要覆盖已发布标签或替换签名；修复后使用新版本标签。手动在 `main` 上运行工作流只做检查，不创建 Release。
