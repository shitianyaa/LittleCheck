# 自定义订阅：模板与使用说明

每个订阅地址返回一个 UTF-8 JSON 文件，HTTP Content-Type 使用 application/json。标准示例见 [feed-v2.example.json](../server/feed-v2.example.json)，JSON Schema 见 [feed-v2.schema.json](../server/feed-v2.schema.json)。客户端同时接受 schema_version 1 和 2。VPS 生成链与 GitHub Pages 镜像自 2026-10-03 起输出 v2；发布端仍接受 v1 订阅，服务端契约见 [server/README.md](../server/README.md)。

## 用 AI 快速上手

把以下三个文件发给能读文件的 AI Agent：

- [feed-v2.example.json](../server/feed-v2.example.json)：订阅格式示例。
- [feed-v2.schema.json](../server/feed-v2.schema.json)：字段类型与必填规则。
- 本说明 `feed-format.md`：使用步骤，以及稳定 ID、去重、图片和失败处理约定。

将下面的 `【来源链接或我提供的内容】` 换成自己的来源，再复制这句话：

> 请按我发给你的 Little Check 模板 `feed-v2.example.json`、格式规范 `feed-v2.schema.json` 和使用说明 `feed-format.md`，把【来源链接或我提供的内容】整理成可订阅的 UTF-8 `feed.json`，保持条目 ID 稳定，保留真实原帖链接和发布时间，完成格式校验，并告诉我如何托管文件及在 App 中添加订阅；缺失的必要信息请列出来让我补充。

例如，将占位替换为「我提供的三篇博客文章」。如果需要持续更新，再告诉 Agent 更新频率和托管环境，例如「每小时更新一次，使用我已有的静态网站」，由它据此配置生成任务。

## 从文件到 App

1. 让 Agent 根据示例生成自己的 `feed.json`。示例中的 `example.com`、仓库和图片地址都是占位；日期替换为内容真实发布时间，不能只改成今天让旧内容显得更新。
2. 校验字段类型、带时区的日期、重复 ID、条目数与文件大小。可选用 [publish_feed.py](../server/publish_feed.py) 校验并原子写入：`python3 publish_feed.py candidate.json feed.json`。脚本路径按实际下载位置调整。
3. 把生成的 `feed.json` 放到手机可访问的静态网站，取得直接返回 JSON 的 HTTP(S) 地址，例如 `https://你的域名/feed.json`。GitHub 仓库预览页不是订阅地址；如用 GitHub Pages，使用站点上文件的直接地址。
4. 打开 App 的「设置 → 订阅源 → 添加订阅源」，填写自定义名称和「JSON 地址」，保存后进入信息流刷新。

需要持续更新时，托管端必须定期重新生成并替换同一地址下的文件。模板只定义数据格式；修改示例不会自动抓取网站或建立定时任务。App 当前不直接导入本地 JSON 文件，也不直接订阅 RSS/Atom，RSS 需先转换成此 JSON 格式。

## 整个订阅的字段

下列字段放在 JSON 最外层；`items` 数组中的每个对象是一条帖子。

| 字段 | 类型 | 必填 | 含义与填写方式 |
| --- | --- | --- | --- |
| `schema_version` | 整数 | 是 | 新订阅固定填 `2`，表示格式版本，和 App 版本无关。 |
| `title` | 字符串 | 否 | 整个订阅的标题，例如「我的科技订阅」；App 中的订阅名称由用户添加时填写。 |
| `description` | 字符串 | 否 | 整个订阅的说明，例如「开源项目与科技动态」。 |
| `generated_at` | 字符串 | 是 | 本次成功生成这份文件的时间，例如 `2026-10-03T08:00:00+08:00`，必须带时区。 |
| `items` | 数组 | 是 | 帖子列表，最多 500 条；整个 UTF-8 JSON 最多 2 MiB。 |

## 每条帖子的字段

| 字段 | 类型 | 必填 | 含义与填写方式 |
| --- | --- | --- | --- |
| `id` | 字符串 | 是 | 帖子唯一且稳定的标识，例如 `github:example/demo`；同一订阅不能重复，同一帖子更新时沿用原 ID。 |
| `title` | 字符串 | 是 | 这条帖子的标题，不能只含空白；和最外层订阅 `title` 是不同字段。 |
| `summary` | 字符串 | 是 | 信息流列表中的摘要，可填空字符串 `""`。 |
| `content` | 字符串 | 是 | 详情页的 Markdown 正文，支持 GFM 待办与图片，可填 `""`。 |
| `platform` | 字符串或 `null` | 否 | 平台标签，例如 `github`、`pixiv`、`twitter`、`博客`、`Mastodon`；缺失、`null` 或空白归为其他。 |
| `source` | 字符串 | 是 | 具体账号、作者或栏目，例如「GitHub Trending」；不同于 App 设置中的订阅名称。 |
| `url` | 字符串或 `null` | 否 | 原帖 HTTP(S) 链接，不能含用户名密码，推荐 HTTPS；用于打开原帖和跨订阅去重。 |
| `published_at` | 字符串 | 是 | 原帖发布时间，必须带时区；抓取失败保留旧帖子时保持原时间。 |
| `tags` | 字符串数组 | 否 | 帖子标签，例如 `["开源", "工具"]`；没有标签时省略或填 `[]`。 |

可选字符串字段没有内容时可省略；只有表中明确允许 `null` 的字段才填写 `null`。必填的 `summary`、`content`、`source` 即使为空也要保留字段，填 `""`。

`generated_at` 是整份文件的生成时间，`published_at` 是每条帖子的原始发布时间。App 默认保留最近七天已接收帖子，旧示例日期可能使条目在刷新合并时被过滤；需要查看更早内容时，在设置中调整保留天数。

为兼容现有源，`platform` 的 `github` / `pixiv` / `twitter` / `other` 分别显示为 GitHub / P站 / X·推特 / 其他，其余名称按原文字显示。App 不根据原帖域名推断平台。

## 图片、合并与更新

图片写入 Markdown：`![说明](https://你的静态站/media/image.webp)`。建议使用稳定的 HTTPS 图片地址，不把图片数据直接放进 JSON；图片源需要对手机直连可用。订阅是 JSON 信息流接口，当前不直接解析任意 RSS/Atom；RSS 在 VPS 聚合脚本中转换为此格式。

同一订阅不能有重复 ID。合并订阅时，相同原帖 URL 去重并保留全部订阅归属，以便筛选；没有 URL 时，以订阅 ID + 条目 ID 区分。URL 不同的镜像链接不做猜测去重。不同订阅独立缓存，单个订阅失败保留其缓存并显示名称和错误，其余正常更新。

发布端先生成临时文件并完整校验，再原子替换。抓取失败不发布空列表、不把 generated_at 更新成新的成功时间。公开订阅中不要放 API Key、私人笔记或账户信息。

`feed-v2.schema.json` 用于结构检查；同一订阅 ID 唯一、文件不超过 2 MiB 等规则需另外检查，`publish_feed.py` 包含这些检查。若使用本项目 Pages 导出器拆分订阅，平台名最多 64 字符；自行托管单个 feed 没有此导出器限制。

`example-feed.json` 是旧 v1 示例；新接入使用 v2。`extra-sources.example.json` 是服务器管理员追加 RSS 来源的配置片段，不能直接作为 App 的订阅 JSON。
