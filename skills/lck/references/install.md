# lck 的安装与升级

**只在用户明确要求安装、升级或修复 lck 时才走这份流程。** 它改动文件系统，不是常规前置检查。

安装前先说明：检测到的平台、目标目录、将要替换的文件，然后等用户确认。

## 批准来源

- 仓库：`https://github.com/shitianyaa/LittleCheck`
- 发布页：`https://github.com/shitianyaa/LittleCheck/releases` — 下载 `lck-windows-x64` 归档与**同一个 tag** 下的 `SHA256SUMS.txt`

本项目**没有安装脚本**。不要获取、即兴编写或执行任何安装器；不要使用镜像站、聊天里贴的 URL、或任何不是本仓库官方 Release 资产的地址。

## 归档内容

`LittleCheck-<tag>-lck-windows-x64.zip` 解压后就是**一个完整的 skill 目录**：

```
SKILL.md               ← 与二进制成对的 skill 文档
bin/lck.exe            ← 单文件可执行程序
references/*.md        ← 命令速查、工作流、排查
LICENSE                ← AGPL-3.0
```

因为二进制与 skill 在同一个归档里，**不存在版本错配**——这正是把它们打包在一起的原因。不要从别处单独取二进制或单独取 skill。

## 安装 / 升级

1. 从 Release 下载 `LittleCheck-<tag>-lck-windows-x64.zip` 与 `SHA256SUMS.txt`。
2. 校验归档：
   ```
   sha256sum -c SHA256SUMS.txt --ignore-missing
   ```
   校验失败就停下报告，不要继续解压。
3. 解压并替换 skill 目录的全部内容（`SKILL.md`、`bin/`、`references/`、`LICENSE`）。
4. 验证成对关系：
   ```
   bin/lck.exe --version     # 形如 lck version <v>
   ```
   与 `SKILL.md` 的 `version:` 字段比对，**必须一致**；不一致说明归档混用了版本，报告这一对，不要继续用。
5. 冒烟：`bin/lck.exe status --json` 应当正常返回数据目录与计数。

升级就是重复这套流程。**没有自更新机制**，lck 不会自己去下载新版本。

## 拒绝条件

以下情形一律停下并报告，不要自行绕过：

- 用户没有明确要求安装/升级/修复。
- 校验和不匹配，或发布页上没有对应 tag 的 `SHA256SUMS.txt`。
- 拿到的归档缺少 `bin/lck.exe`、`SKILL.md` 或 `LICENSE`。
- 解压后 `--version` 与 `SKILL.md` 的 `version:` 不一致。
- 有人给出非本仓库 Release 的下载地址（包括"镜像更快"这类理由）。

## 与源码构建的关系

仓库内的 `bin/build_lck.ps1` 是维护者构建二进制的脚本（见仓库根 `AGENTS.md`），**不是给使用者用的安装方式**。普通使用者应当走上面的 Release 流程；只有在本仓库内开发 lck 时才需要源码构建。

## 许可

lck 是 Little Check 的一部分，以 **AGPL-3.0** 发布，归档内的 `LICENSE` 是全文。源码在同一个仓库；分发二进制时必须一并提供对应源码或指向它的位置。
