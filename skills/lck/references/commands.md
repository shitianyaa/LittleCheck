# lck 命令速查

> 真源是 `lck <命令> --help`。本表随 0.1.0 编写，可能滞后于二进制。
> 每个命令都有独立帮助：`lck note new --help`、`lck task done --help`。

## 全局选项

| 选项 | 含义 |
| --- | --- |
| `--data-dir <路径>` | 指定数据目录；缺省读 bootstrap。用 `lck status` 查看实际生效的目录。也可用环境变量 `LCK_DATA_DIR` |
| `--json` | 输出结构化 JSON（单条=对象，多条=数组，空=`[]`） |
| `--help`, `-h` | 显示帮助 |
| `--version` | 显示版本 |

## 只读命令

| 命令 | 说明 |
| --- | --- |
| `status` | 数据目录、文件夹数、笔记数（含回收站）、删除标记数 |
| `today` | 今日足迹：活跃/信息流阅读/AI 调用/笔记字数/完成待办/是否归档 |
| `folder list` | 列出文件夹（ID、名称、笔记数） |
| `note list [--folder X] [--trash]` | 列笔记；`--trash` 列回收站，`--folder` 按文件夹过滤 |
| `note show <ID\|关键词>` | 输出笔记正文（`--json` 含 `content`） |
| `note search <关键词>` | 按标题/正文全文搜索 |
| `task list [--all] [--note X]` | 汇总待办；默认只列未完成，`--all` 含已完成 |

## 写入命令

| 命令 | 说明 |
| --- | --- |
| `folder new <名称>` | 新建文件夹（名称唯一，≤80 字符） |
| `folder rm <名称\|ID>` | 删除文件夹，内含笔记移入回收站 |
| `note new [--title T] [--folder F] [--body B] [--body-file F]` | 新建笔记 |
| `note append <ID\|关键词> [--body B] [--body-file F]` | 追加正文（自动补空行；不接受 `--title`） |
| `note edit <ID\|关键词> [--title T] [--body B] [--body-file F]` | 覆盖正文 |
| `note mv <ID\|关键词> [--folder F]` | 移动笔记；省略 `--folder` 移到根目录 |
| `note rm <ID\|关键词>` | 移入回收站 |
| `note restore <ID\|关键词>` | 从回收站恢复 |
| `note purge <ID\|关键词> --yes` | 永久删除（不可恢复，必须 `--yes`） |
| `task add "<文本>" [--note X] [--folder F]` | 新增待办；默认追加到「待办清单」笔记 |
| `task done <关键词> [--note X]` | 勾选唯一匹配的未完成待办 |

## 正文来源

`--body B` 直接给文本；`--body-file <path>` 读文件；`--body-file -` 读 stdin；
三者都未给且 stdin 非终端时从 stdin 读。正文**原样落盘**，不做格式处理。

优先级：`--body` > `--body-file` > stdin。

**在 Windows 上优先用 stdin 或 `--body-file`，不要用 argv 传含换行的正文**：
经批处理转发时换行会破坏参数（已实测）。单行正文用 `--body` 没问题。

## 选项严格化

每个命令只接受自己声明的选项与标志，外加全局项 `--data-dir`、`--json`。
传了未声明的一律退出码 2，**不会静默忽略**：

```bash
lck note rm <ID> --title T      # 用法错误：note rm 不接受 --title
lck task list --trash           # 用法错误：task list 不接受 --trash
lck note --trash                # OK：等价于 note list --trash（命令组默认 list）
```

各命令接受什么，以 `lck <命令> --help` 为准。

## 退出码

| 码 | 含义 |
| --- | --- |
| `0` | 成功 |
| `1` | 运行时失败（数据损坏、IO 错误） |
| `2` | 用法错误（参数不合法、找不到或匹配到多篇笔记/待办） |

## 帮助路径

`lck help <路径>` 与 `lck <路径> --help` 等价：

```bash
lck help                  # 全局帮助
lck help note             # note 组
lck help note new         # 单命令
lck note new --help       # 同上
```

命令组下遇到不认识的 token 一律按未知子命令处理（退出码 2），不回退显示父组帮助。

## 排查

报错信息、退出码与数据目录问题见 [troubleshooting.md](troubleshooting.md)。
