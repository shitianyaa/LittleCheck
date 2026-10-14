#!/usr/bin/env pwsh
<#
.SYNOPSIS
  构建 lck 单文件可执行程序，并注入版本、commit 与构建时间。

.DESCRIPTION
  lck 是纯 Dart CLI：运行时闭包只有 dart:io/convert/async/math 加 crypto、
  markdown 两个包，与 Flutter 无关。

  为什么不能直接 `dart compile exe bin/lck.dart`：App 的包图有 113 个包，其中
  mobile_scanner 的传递依赖 objective_c 带 native build hook，`dart compile exe`
  一旦在包配置里看到带 hook 的包就直接拒绝（"'dart compile' does not support
  build hooks"），而它检查的是默认的 .dart_tool/package_config.json ——
  `--packages` 参数不生效（已实测）。绕道 `dart build cli` 也不行：hook 运行器
  不引用含空格的路径，本项目路径会让它报 `'D:\Project\Little' 不是内部或外部命令`。

  所以本脚本生成一个**自包含的最小包**再编译：

    1. 从 bin/lck.dart 出发，按 import/export 递归算出源码闭包（不硬编码文件表，
       改了导入关系也会自动跟上）；
    2. 从闭包里的 `package:X` 导入反推需要哪些外部包，再**从仓库根 pubspec.yaml
       取这些包的版本约束** —— 单一真源，不存在两处声明漂移的可能；
    3. 在 build/lck_pkg/ 生成该包（pubspec + 闭包源码按原相对路径复制），
       在那里 `dart pub get`，再编译。

  这样构建不依赖 Flutter 工程，也不依赖 App 的 .dart_tool/package_config.json。
  闭包内的源码每次从仓库重新复制，不存在副本漂移。

  版本号取自仓库根 pubspec.yaml 的 version 去掉 +build 后缀，并与
  skills/lck/SKILL.md 的 version 字段比对 —— 两者成对发布，不一致即失败。

.PARAMETER Output
  输出路径。默认 build/lck/lck.exe。

.PARAMETER Dart
  dart 可执行文件路径。默认取 $env:FLUTTER_ROOT 下的 dart，否则用 PATH 上的 dart。
  纯 Dart SDK 即可，不需要 Flutter。

.PARAMETER Offline
  用 `dart pub get --offline`（仅用本地 pub 缓存）。CI 与首次构建请勿使用。

.PARAMETER SkipVersionCheck
  跳过与 skills/lck/SKILL.md 的版本比对（仅用于临时构建）。

.EXAMPLE
  pwsh bin/build_lck.ps1
  pwsh bin/build_lck.ps1 -Output D:/tmp/lck.exe
#>
[CmdletBinding()]
param(
    [string]$Output,
    [string]$Dart,
    [switch]$Offline,
    [switch]$SkipVersionCheck
)

$ErrorActionPreference = 'Stop'

# 递归求 bin/lck.dart 的源码闭包。
# 返回 @{ Files = <仓库内绝对路径集合>; Packages = <外部包名集合> }。
# 只跟随 dart: 之外的 import/export；package:little_check/* 映射回 lib/。
function Get-DartSourceClosure {
    param([string]$EntryPoint, [string]$RepoRoot)

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $packages = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue([System.IO.Path]::GetFullPath($EntryPoint))

    $pattern = "(?m)^\s*(?:import|export)\s+['""]([^'""]+)['""]"
    while ($queue.Count -gt 0) {
        $file = $queue.Dequeue()
        if (-not $seen.Add($file)) { continue }
        if (-not (Test-Path -LiteralPath $file)) {
            throw "闭包里的源文件不存在：$file"
        }
        $text = [System.IO.File]::ReadAllText($file, [System.Text.UTF8Encoding]::new($false))
        foreach ($match in [regex]::Matches($text, $pattern)) {
            $import = $match.Groups[1].Value
            if ($import.StartsWith('dart:')) { continue }
            if ($import.StartsWith('package:little_check/')) {
                $rel = $import.Substring('package:little_check/'.Length)
                $queue.Enqueue([System.IO.Path]::GetFullPath((Join-Path $RepoRoot "lib/$rel")))
                continue
            }
            if ($import.StartsWith('package:')) {
                # package:foo/bar.dart -> foo
                $rest = $import.Substring('package:'.Length)
                $slash = $rest.IndexOf('/')
                if ($slash -gt 0) { [void]$packages.Add($rest.Substring(0, $slash)) }
                continue
            }
            $queue.Enqueue([System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $file) $import)))
        }
    }
    return [pscustomobject]@{ Files = $seen; Packages = $packages }
}

# 从 pubspec 文本里取顶层 dependencies: 段的 `名字: 约束` 映射。
# 只用于仓库根 pubspec.yaml（纯 ASCII），不用于含非 ASCII 注释的文件：
# PowerShell 5.1 按 ANSI 码页读 UTF-8 无 BOM 文件时，乱码字节会吞掉换行。
function Get-PubspecDependencies {
    param([string]$Text)

    $deps = @{}
    $inDeps = $false
    foreach ($line in ($Text -split "`n")) {
        $t = $line.TrimEnd("`r")
        if ($t -match '^([A-Za-z_][A-Za-z0-9_-]*):') {
            $inDeps = ($Matches[1] -eq 'dependencies')
            continue
        }
        if (-not $inDeps) { continue }
        if ($t -match '^\s+([A-Za-z_][A-Za-z0-9_-]*):\s*(\S.*?)\s*$') {
            $deps[$Matches[1]] = $Matches[2]
        }
    }
    return $deps
}

# 写 UTF-8 无 BOM 文本（PS 5.1 的 -Encoding UTF8 会加 BOM）。
function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    # --- 1. 版本号与依赖：仓库根 pubspec.yaml ---------------------------------
    $pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
    if (-not (Test-Path -LiteralPath $pubspecPath)) {
        throw "找不到 pubspec.yaml：$pubspecPath"
    }
    $pubspec = [System.IO.File]::ReadAllText($pubspecPath, [System.Text.UTF8Encoding]::new($false))
    if ($pubspec -notmatch '(?m)^version:\s*(\S+)') {
        throw 'pubspec.yaml 里找不到 version: 字段'
    }
    $version = $Matches[1] -replace '\+.*$', ''
    $appDeps = Get-PubspecDependencies -Text $pubspec
    if ($appDeps.Count -eq 0) {
        throw 'pubspec.yaml 里没解析出任何依赖，检查文件格式'
    }

    # --- 2. commit -----------------------------------------------------------
    $commit = 'unknown'
    try {
        $raw = git rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $commit = ($raw | Select-Object -First 1).Trim()
        }
    } catch {
        Write-Warning '取不到 git commit，按 unknown 记录'
    }

    # --- 3. 构建时间（UTC, ISO8601） -----------------------------------------
    $buildDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # --- 4. 与 skill 的 version 成对校验 --------------------------------------
    # 缺文件或缺字段时也失败（除非显式 -SkipVersionCheck）：静默降级会让「成对发布」
    # 的保证在全新检出或误删后无声失效。
    $skillPath = Join-Path $repoRoot 'skills/lck/SKILL.md'
    if (Test-Path -LiteralPath $skillPath) {
        $skill = [System.IO.File]::ReadAllText($skillPath, [System.Text.UTF8Encoding]::new($false))
        if ($skill -match '(?m)^version:\s*(\S+)') {
            $skillVersion = $Matches[1].Trim()
            if ($skillVersion -ne $version) {
                if ($SkipVersionCheck) {
                    Write-Warning "版本不一致（已跳过）：pubspec=$version，skills/lck/SKILL.md=$skillVersion"
                } else {
                    throw "版本不一致：pubspec=$version，skills/lck/SKILL.md=$skillVersion。两者成对发布，请同步后重试（或加 -SkipVersionCheck）。"
                }
            }
        } elseif ($SkipVersionCheck) {
            Write-Warning 'skills/lck/SKILL.md 里找不到 version: 字段（已跳过成对校验）'
        } else {
            throw 'skills/lck/SKILL.md 里找不到 version: 字段，无法成对校验（或加 -SkipVersionCheck）。'
        }
    } elseif ($SkipVersionCheck) {
        Write-Warning '找不到 skills/lck/SKILL.md（已跳过成对校验）'
    } else {
        throw '找不到 skills/lck/SKILL.md，无法成对校验（或加 -SkipVersionCheck）。'
    }

    # --- 5. dart 可执行文件 ---------------------------------------------------
    # 解析顺序：-Dart 参数 > $env:FLUTTER_ROOT > PATH 上的 dart。
    # 不硬编码本机 SDK 路径：换机器后应当报错，而不是静默用错版本。
    if (-not $Dart) {
        if ($env:FLUTTER_ROOT) {
            $candidate = Join-Path $env:FLUTTER_ROOT 'bin/cache/dart-sdk/bin/dart.exe'
            if (Test-Path -LiteralPath $candidate) { $Dart = $candidate }
        }
        if (-not $Dart) {
            $onPath = Get-Command dart -ErrorAction SilentlyContinue
            if ($onPath) { $Dart = $onPath.Source }
        }
    }
    if (-not $Dart) {
        throw '找不到 dart。请用 -Dart <路径> 指定，或设置 FLUTTER_ROOT 环境变量（纯 Dart SDK 即可）。'
    }
    if (-not (Get-Command $Dart -ErrorAction SilentlyContinue)) {
        throw "dart 不可执行：$Dart"
    }

    # --- 6. 输出路径 ---------------------------------------------------------
    # 规范化为绝对路径：编译步骤会 Push-Location 到生成包目录，相对路径会在那里
    # 解析（产物落到 build/lck_pkg/，下次运行被整个删除），而自检又在仓库根解析
    # —— 两处不一致会检查错文件。
    if (-not $Output) {
        $Output = Join-Path $repoRoot 'build/lck/lck.exe'
    }
    $Output = [System.IO.Path]::GetFullPath($Output)
    $outDir = Split-Path -Parent $Output
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }

    # --- 7. 算闭包并生成自包含的最小包 ----------------------------------------
    $closure = Get-DartSourceClosure -EntryPoint (Join-Path $repoRoot 'bin/lck.dart') -RepoRoot $repoRoot

    # 闭包需要的每个外部包，其版本约束必须能在根 pubspec 的 dependencies 里找到。
    $depLines = New-Object System.Collections.Generic.List[string]
    foreach ($name in ($closure.Packages | Sort-Object)) {
        if (-not $appDeps.ContainsKey($name)) {
            throw "闭包导入了 package:$name，但仓库根 pubspec.yaml 的 dependencies 里没有它。请补上，或去掉该导入。"
        }
        $depLines.Add("  ${name}: $($appDeps[$name])")
    }
    if ($depLines.Count -eq 0) {
        throw '闭包没有解析出任何外部依赖，检查 Get-DartSourceClosure 的正则是否失效'
    }

    $pkgDir = Join-Path $repoRoot 'build/lck_pkg'
    if (Test-Path -LiteralPath $pkgDir) { Remove-Item -Recurse -Force -LiteralPath $pkgDir }
    New-Item -ItemType Directory -Force -Path (Join-Path $pkgDir 'bin') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $pkgDir 'lib') | Out-Null

    # 生成的 pubspec 保持纯 ASCII：PS 5.1 读非 ASCII 文件有编码陷阱（见函数注释）。
    $pkgPubspec = @(
        '# Generated by bin/build_lck.ps1 - do not edit.',
        '# Dependency constraints are copied from the repository root pubspec.yaml,',
        '# so there is a single source of truth and no drift is possible.',
        'name: little_check',
        'description: Little Check workbench CLI (lck).',
        'publish_to: none',
        "version: $version",
        '',
        'environment:',
        '  sdk: ^3.13.5',
        '',
        'dependencies:'
    ) + $depLines + @('')
    Write-Utf8NoBom -Path (Join-Path $pkgDir 'pubspec.yaml') -Text ($pkgPubspec -join "`n")

    $copied = 0
    foreach ($file in $closure.Files) {
        $rel = $file.Substring($repoRoot.Length).TrimStart('\', '/')
        if ($rel.StartsWith('..')) {
            throw "闭包里的文件在仓库之外，无法按相对路径复制：$file"
        }
        $dest = Join-Path $pkgDir $rel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        }
        Copy-Item -LiteralPath $file -Destination $dest -Force
        $copied++
    }

    Write-Host "lck $version (commit $commit, built $buildDate)"
    Write-Host "dart:    $Dart"
    Write-Host "output:  $Output"
    Write-Host "closure: $copied 个源文件；依赖：$(($closure.Packages | Sort-Object) -join ', ')"

    # --- 8. 解析依赖并编译 ----------------------------------------------------
    Push-Location $pkgDir
    try {
        $pubArgs = @('pub', 'get')
        if ($Offline) { $pubArgs += '--offline' }
        & $Dart @pubArgs
        if ($LASTEXITCODE -ne 0) {
            throw "dart pub get 失败（退出码 $LASTEXITCODE）"
        }

        & $Dart compile exe bin/lck.dart `
            "-DLCK_VERSION=$version" `
            "-DLCK_COMMIT=$commit" `
            "-DLCK_BUILD_DATE=$buildDate" `
            -o $Output
        if ($LASTEXITCODE -ne 0) {
            throw "dart compile exe 失败（退出码 $LASTEXITCODE）"
        }
    } finally {
        Pop-Location
    }

    # --- 9. 自检：产出的二进制版本行 ------------------------------------------
    # 自检失败时删掉产物：否则会残留一个版本不对的二进制，下次看起来「构建过了」。
    $line = (& $Output --version | Select-Object -First 1).Trim()
    Write-Host "verify:  $line"
    if ($line -ne "lck version $version") {
        Remove-Item -Force -LiteralPath $Output -ErrorAction SilentlyContinue
        throw "产出的二进制版本行与预期不符：期望 'lck version $version'，实际 '$line'（已删除该产物）"
    }
} finally {
    Pop-Location
}
