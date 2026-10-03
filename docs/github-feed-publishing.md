# 使用 GitHub Pages 发布订阅

适用于已经能通过公开 HTTPS 地址提供 `feed.json` 和图片的服务器。制作订阅内容先看 [模板与使用说明](feed-format.md)；本文说明如何增加 Pages 镜像。

## 部署步骤

1. 创建自己的 Pages 发布仓库，复制 `server/export_github_site.py`、`server/publish_feed.py` 和 `server/test_export_github_site.py`，保留它们在 `server/` 下的路径。
2. 将 [工作流模板](../server/github-pages-workflow.yml) 保存为 `.github/workflows/publish.yml`，在仓库 Pages 设置中选择 **GitHub Actions**。
3. 在仓库 Actions variables 中明确配置以下三项，替换为自己的地址。模板中的默认源站是示例，不应作为自建订阅的配置。

| 变量 | 示例与用途 |
| --- | --- |
| `PAGES_BASE_URL` | `https://YOUR_USER.github.io/YOUR_REPO`，发布后的站点根地址 |
| `FEED_SOURCE` | `https://feed.example.com/feed.json`，公开 JSON 地址 |
| `FEED_MEDIA_BASE` | `https://feed.example.com/media`，公开图片目录 |

4. 手动运行工作流，确认 `/feed.json` 和引用的图片可访问，再在 App 中添加 JSON 地址。模板同时提供每小时定时触发；执行时间可能因排队延后。

Actions 从公开源读取内容，Pages 部署使用工作流的临时权限。只发布允许公开的帖子和图片，不上传笔记、来源账号配置、密钥或服务器日志。

## 输出与缓存

- `/feed.json`：总订阅。
- `/feeds/*.json`：按平台、RSS 来源拆分的订阅。
- `/subscriptions.json`：当前非空订阅的名称与地址；App 目前需要手动添加，不自动导入此列表。
- `/media/`：已缓存的 WebP 图片。

普通 ASCII 平台名保留直观文件名；中文、特殊字符及保留前缀平台使用 `platform-<SHA256>.json`，显示名称不变。平台与 RSS 使用独立分组，避免同名混淆。

导出器只搬运源站已缓存的 WebP，其他图片链接保持原样。图片按最后引用时间清理，Actions 缓存可能被淘汰，不能当作长期图片档案。导出准备失败时不部署，保留上次站点；生成时间保留源站值。

App 的 ETag 请求在收到 304 时复用缓存，收到 200 时下载完整 JSON；它不是差量同步。Pages 与源站独立发布，源站删除图片不会立即删除已发布的 Pages 副本。

## 服务器主动触发（可选）

如需生成成功后立即请求更新，可以在服务器上用 GitHub CLI 触发自己的工作流：

```sh
gh workflow run publish.yml --repo YOUR_USER/YOUR_REPO --ref main
```

仅在生成和发布成功后执行；触发失败应报告错误并保留已发布的 JSON。请求被接受不代表 Pages 已部署成功，还需检查 Actions 结果和公开 JSON 的 `generated_at`。

仓库中的 `trigger_github_workflow.py` 是一份已有部署适配实现，包含固定账号核验和仓库目标。复用前必须改成自己的账号与仓库，并使用独立的 GitHub CLI 登录目录；不要原样调用。`hourly-job.sh` 同样需要检查部署路径、Python 环境和工具 PATH。

## 检查

```sh
python3 -B -m unittest discover -s server -p test_export_github_site.py -v
```

先用自己的源数据验证总订阅、分订阅和图片，再启用定时任务。Pages 限制与 Actions 计费以 [Pages 官方说明](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits) 和 [Actions 官方说明](https://docs.github.com/en/billing/concepts/product-billing/github-actions) 为准。
