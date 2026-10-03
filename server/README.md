# VPS 信息流

不新增常驻业务进程：Hermes 每小时生成 JSON，现有 Nginx/Caddy 提供静态文件。抓取、摘要生成沿用你的 Hermes 配置。本目录负责验证、发布和定义客户端契约。

## 文件一览

| 文件 | 职责 | 运行位置 |
| --- | --- | --- |
| `hourly-job.sh` | cron 入口：生成加锁与十分钟超时，成功后触发 Pages，写日志 | VPS |
| `trigger_github_workflow.py` | 使用独立登录校验账号并触发 Pages 工作流 | VPS（需 GitHub CLI） |
| `generate_feed.py` | 每小时生成器：抓取各来源、缓存压缩图片、写 candidate 并调发布器 | VPS（需 Pillow） |
| `rss_sources.py` | RSS/Atom 抓取与正文转纯文本，被生成器引用 | VPS |
| `publish_feed.py` | 校验 v1/v2 JSON、原子写入 feed.json | VPS、Pages 独立仓库 |
| `export_github_site.py` | 导出 Pages 站点：总订阅、按平台/RSS 拆分订阅、图片地址改写 | Pages 独立仓库 Actions |
| `github-pages-workflow.yml` | Pages 发布仓库的 Actions 模板 | Pages 独立仓库 |
| `example-feed.json` / `feed-v2.example.json` | v1 / v2 格式示例，新接入以 v2 为准 | 本地参考 |
| `feed-v2.schema.json` | v2 的 JSON Schema | 本地参考 |
| `extra-sources.example.json` | 生成器 `extra_sources` 配置片段 | 本地参考 |
| `test_*.py` | 各脚本回归测试 | 本地 / VPS |

## 接入步骤

普通用户制作自定义订阅，先看 [模板与使用说明](../docs/feed-format.md)，其中包含可以直接发给 AI Agent 的一句话提示词、完整字段表与 App 操作步骤。下文是服务器生成与发布链的接入方式。

1. 给 Hermes 提供 `feed-v2.example.json` 作为格式参考（`example-feed.json` 是 v1 旧例，客户端仍兼容），修改为你的主题、来源和实际内容。条目 ID 使用来源 URL 或稳定标识；同一条内容更新时沿用 ID。建议每次输出最近一段时间的完整列表。
2. 输出到不公开的候选文件，例如 `/opt/little-check/candidate.json`。
3. Hermes 生成成功后执行：

```sh
python3 /opt/little-check/publish_feed.py /opt/little-check/candidate.json /var/www/little-check/feed.json
```

也支持标准输入：`python3 publish_feed.py - /var/www/little-check/feed.json`。

4. Nginx/Caddy 通过 HTTPS 提供 `feed.json`，App 设置里填写完整 URL。

已有 Hermes 调度功能时直接每小时执行现有任务；没有时使用 cron。下面只是一小时一次的**发布步骤**示例；必须放到抓取和生成成功后的流程里，不能把旧候选文件当作新结果反复发布：

```cron
0 * * * * /opt/little-check/hourly-job.sh
```

仓库中的 `hourly-job.sh` 调用 `generate_feed.py`，脚本内部已加锁，不要在 cron 外层再加同一把锁。复用前检查脚本内的部署路径、Python 环境、工具 PATH 与 Pages 触发账号/仓库。如果使用自己的生成器，请替换成已验证的生成命令，成功后调用发布器。调度时区由服务器设置决定。

## JSON 契约

发布器同时接受 `schema_version` `1` 和 `2`，生成器输出 `2`。面向客户端的完整字段说明见 [feed-format.md](../docs/feed-format.md)。

- `schema_version`: 整数 `1` 或 `2`。v2 允许订阅级可选 `title`/`description` 文字；v2 的 `platform` 是自由平台名称，缺失、null 或空白由客户端归为其他；v1 仍限定 `platform` 为 `github`、`pixiv`、`twitter`、`other`。
- `generated_at`: 本次成功生成时间，带时区的 ISO8601，例如 `2026-10-02T08:00:00Z`。失败时保留原值。
- `items`: 最多 500 条，整个文件 UTF-8 大小最多 2 MiB。
- 每项 `id`、`title`、`summary`、`content`、`source`、`published_at` 必填字符串。ID 唯一、标题非空，正文使用 GFM Markdown。
- `url`: 可选 HTTP(S) 原始来源地址，不包含用户名密码。
- `tags`: 可选字符串数组。

更新失败：发布器退出码 `1`，错误写到 stderr，**原 feed.json 不变**。正常退出码 `0`。采用同目录临时文件、flush/fsync 和 `os.replace`，读者不会读到半截文件。App 通过内容生成时间识别旧内容，不伪造新的成功时间。

## Nginx 示例

把以下 location 合入你已有的 HTTPS server 块，保留你当前的证书、域名和其他路由配置：

```nginx
location = /feed.json {
    root /var/www/little-check;
    default_type application/json;
    charset utf-8;
    etag on;
    add_header Cache-Control "no-cache" always;
    try_files $uri =404;
}
```

App 使用 ETag/If-None-Match，304 时复用本地缓存；请求或内容校验失败时继续展示旧数据。初版网址内容是公开静态文件，只放允许通过该网址访问的内容，笔记不上传。

## 验证

```sh
python3 -m unittest discover -s server -p test_publish_feed.py -v
```

## 生成器与定时任务

`generate_feed.py` 依赖 Pillow，依赖固定在 `requirements.txt`；发布器使用 Python 标准库。请为生成器配置独立 Python 环境，并检查来源配置、输出位置与图片托管地址。脚本和配置中存在已有部署的固定路径及目标，复用前按自己的部署修改。

`hourly-job.sh` 为生成器提供锁和十分钟期限。生成失败或已有任务占锁时不触发 Pages；成功后调用 `trigger_github_workflow.py`。触发器核验登录身份，再请求工作流运行；账号与仓库目标需修改为自己的值。触发失败会明确报错并保留已发布的 feed，不自动重试。

图片下载最多两路并发，压缩为 WebP，已有图片按内容复用。缓存清理仅在发布成功后执行，保护当前、上一版引用及七天内的图片；受保护图片超过容量时保留并警告。部分来源失败时保留其旧内容，所有启用来源均无新结果时不更新 feed 或生成时间。

## RSS 来源

`rss_sources.py` 支持 RSS 2.0 与 Atom，保留发布时间、来源和原文 URL，以稳定 URL 生成 ID。HTML 正文转为纯文本，不执行其中的代码。来源失败时保留旧内容并记录警告。

[extra-sources.example.json](extra-sources.example.json) 是生成器配置片段，供管理员合并 `extra_sources`。每个来源需要唯一且稳定的 `id`、名称、公开 HTTPS 地址、条数上限和启用状态；添加来源时同时检查总条数上限。这不是给 App 直接订阅的 JSON。

## Pages 镜像

`export_github_site.py` 导出总订阅、动态平台/RSS 分订阅及图片；工作流部署完整站点，不把每小时图片写入 Git 历史。部署和可选主动触发方式见 [GitHub Pages 通用教程](../docs/github-feed-publishing.md)。

## 完整测试

在已安装 `requirements.txt` 依赖的环境运行：

```sh
python3 -B -m unittest discover -s server -v
```
