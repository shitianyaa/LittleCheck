// lck 的帮助文本数据源。
//
// 设计：帮助是**数据**，不是散落在命令实现里的字符串。全局帮助、命令组帮助
// 与单命令帮助都由这里的 kCommandHelps 渲染，避免「help 说一套、实现做一套」。
//
// 同一份数据还承担**选项校验**：每个命令声明自己接受的选项与标志，_run 据此
// 拒绝未声明的参数（退出码 2），而不是静默忽略。所以新增命令或选项时只改这里。
//
// 语义真源约定（与 skills/lck/SKILL.md 一致）：`lck <命令> --help` 是命令语义
// 的权威来源；本文件必须随命令面同步更新，契约测试覆盖每个命令的 --help。
//
// 本文件只做数据、查找与渲染，不抛错误、不做控制流：未知子命令该不该报错
// 由调用方（bin/lck.dart）决定。

/// 命令的副作用档位。决定全局帮助分组，也提示 Agent 该按什么规则操作。
enum CommandTier {
  /// 只读，随时可执行。
  readOnly,

  /// 本地写入但可恢复（回收站、可改回）。
  localWrite,

  /// 不可逆（永久删除）。
  irreversible,
}

/// 一条取值选项：`--title T`。
class HelpOption {
  const HelpOption(this.flag, this.description);

  /// 显示用原文，如 `--title T`。
  final String flag;

  final String description;

  /// 选项名（不含取值占位），如 `--title`。供参数校验使用。
  String get name =>
      flag.contains(' ') ? flag.substring(0, flag.indexOf(' ')) : flag;
}

/// 一个布尔标志：`--trash`。
class HelpFlag {
  const HelpFlag(this.name, this.description);

  final String name;
  final String description;
}

/// 一个命令（或命令组）的帮助条目。
class CommandHelp {
  const CommandHelp({
    required this.path,
    required this.usage,
    required this.summary,
    this.tier = CommandTier.readOnly,
    this.defaultSubcommand,
    this.options = const <HelpOption>[],
    this.flags = const <HelpFlag>[],
    this.examples = const <String>[],
    this.notes = const <String>[],
  });

  /// 命令路径，如 `['note', 'new']`；空列表表示全局帮助。
  final List<String> path;

  /// 用法行（不含 `lck ` 前缀），用于单命令帮助。
  final String usage;

  /// 一句话说明；同时用作全局索引与单命令帮助标题。
  final String summary;

  /// 副作用档位。
  final CommandTier tier;

  /// 命令组在不带子命令时默认执行的子命令（如 `note` → `list`）。
  /// 仅命令组需要；用于把 `lck note --trash` 校验到 `note list` 上。
  final String? defaultSubcommand;

  /// 本命令特有的取值选项。
  final List<HelpOption> options;

  /// 本命令特有的布尔标志。
  final List<HelpFlag> flags;

  /// 可直接照抄的示例（不含 `lck ` 前缀）。
  final List<String> examples;

  /// 补充说明（如「--title 会被拒绝」这类跨选项约束）。
  final List<String> notes;

  /// 全局索引里显示的名字。
  String get indexLabel => path.join(' ');

  /// 是否是命令组（有子命令）。
  bool get isGroup => _groupChildren.isNotEmpty;

  /// 本组直接子命令。
  List<CommandHelp> get children => _groupChildren;

  /// 本命令接受的取值选项名（不含全局项）。
  Set<String> get acceptedOptionNames => {for (final o in options) o.name};

  /// 本命令接受的布尔标志名（不含全局项）。
  Set<String> get acceptedFlagNames => {for (final f in flags) f.name};

  List<CommandHelp> get _groupChildren => [
    for (final c in kCommandHelps)
      if (c.path.length == path.length + 1 &&
          _isPrefix(path, c.path) &&
          c.path.isNotEmpty)
        c,
  ];
}

bool _isPrefix(List<String> prefix, List<String> value) {
  if (prefix.length > value.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (prefix[i] != value[i]) return false;
  }
  return true;
}

/// 全局取值选项：任何命令都接受。
const Set<String> kGlobalOptionNames = {'--data-dir'};

/// 全局布尔标志：任何命令都接受。
/// `--help`/`-h`/`--version` 在分发前就已返回，不进入校验。
const Set<String> kGlobalFlagNames = {'--json'};

/// 全部命令帮助。顺序即渲染顺序。
const List<CommandHelp> kCommandHelps = <CommandHelp>[
  // ---------------------------------------------------------------- 只读
  CommandHelp(
    path: ['status'],
    usage: 'status',
    summary: '数据目录、笔记/文件夹计数、删除标记',
    examples: ['lck status --json'],
  ),
  CommandHelp(
    path: ['today'],
    usage: 'today',
    summary: '今日足迹（活跃/阅读/AI/字数/待办）',
    examples: ['lck today --json'],
  ),
  CommandHelp(
    path: ['folder'],
    usage: 'folder <子命令> [选项]',
    summary: '文件夹管理',
    defaultSubcommand: 'list',
    examples: ['lck folder list --json', 'lck folder new 工作台'],
  ),
  CommandHelp(
    path: ['folder', 'list'],
    usage: 'folder list',
    summary: '列出文件夹（ID、名称、笔记数）',
    examples: ['lck folder list --json'],
  ),
  CommandHelp(
    path: ['folder', 'new'],
    usage: 'folder new <名称>',
    summary: '新建文件夹（名称唯一，≤80 字符）',
    tier: CommandTier.localWrite,
    examples: ['lck folder new 工作台'],
  ),
  CommandHelp(
    path: ['folder', 'rm'],
    usage: 'folder rm <名称|ID>',
    summary: '删除文件夹；内含笔记移入回收站',
    tier: CommandTier.localWrite,
    examples: ['lck folder rm 临时草稿'],
    notes: ['文件夹本身会消失，内含笔记进回收站（不永久删除笔记）。执行前先向用户确认。'],
  ),
  CommandHelp(
    path: ['note'],
    usage: 'note <子命令> [选项]',
    summary: '笔记的读取、搜索与增删改',
    defaultSubcommand: 'list',
    examples: [
      'lck note list --json',
      'lck note show 我的外脑概况 --json',
      'printf "# 标题\\n正文\\n" | lck note new --folder 工作台',
    ],
  ),
  CommandHelp(
    path: ['note', 'list'],
    usage: 'note list [--folder X] [--trash]',
    summary: '列出笔记；按更新时间倒序',
    options: [HelpOption('--folder X', '只列该文件夹（名称或 ID）')],
    flags: [HelpFlag('--trash', '列回收站而不是正常笔记')],
    examples: [
      'lck note list --json',
      'lck note list --folder 工作台',
      'lck note list --trash',
    ],
  ),
  CommandHelp(
    path: ['note', 'show'],
    usage: 'note show <ID|关键词>',
    summary: '输出笔记正文（原文透传）',
    examples: [
      'lck note show 我的外脑概况',
      'lck note show 1791611506089097_2464267262 --json',
    ],
    notes: ['正文原文输出；元数据只在 --json 里。'],
  ),
  CommandHelp(
    path: ['note', 'search'],
    usage: 'note search <关键词>',
    summary: '按标题与正文全文搜索（忽略大小写）',
    examples: ['lck note search 待办 --json'],
  ),
  CommandHelp(
    path: ['note', 'new'],
    usage: 'note new [--title T] [--folder F] [--body B | --body-file -]',
    summary: '新建笔记；正文为纯 markdown 透传',
    tier: CommandTier.localWrite,
    options: [
      HelpOption('--title T', '标题；等价于把 `# T` 放在正文首行'),
      HelpOption('--folder F', '放入文件夹（名称或 ID）；省略则放根目录'),
      HelpOption('--body B', '正文文本'),
      HelpOption('--body-file F', '从文件读正文；`-` 表示 stdin'),
    ],
    examples: [
      'lck note new --title "会议记录" --body "正文…"',
      'printf "# 标题\\n正文\\n" | lck note new --folder 工作台',
    ],
    notes: [
      '正文自带标题行（首行以 # 开头）时不能再传 --title，否则用法错误。',
      'Windows 上含换行的正文请走 stdin 或 --body-file，不要用 --body。',
    ],
  ),
  CommandHelp(
    path: ['note', 'append'],
    usage: 'note append <ID|关键词> [--body B | --body-file -]',
    summary: '在正文末尾追加内容（自动补空行分隔）',
    tier: CommandTier.localWrite,
    options: [
      HelpOption('--body B', '要追加的文本'),
      HelpOption('--body-file F', '从文件读；`-` 表示 stdin'),
    ],
    examples: ['printf "## 追加\\n内容\\n" | lck note append 我的外脑概况'],
    notes: ['不接受 --title：追加不改变标题，传了即用法错误。改标题用 note edit。'],
  ),
  CommandHelp(
    path: ['note', 'edit'],
    usage: 'note edit <ID|关键词> [--title T] [--body B | --body-file -]',
    summary: '覆盖整篇正文（不是追加）',
    tier: CommandTier.localWrite,
    options: [
      HelpOption('--title T', '新标题；等价于把 `# T` 放在正文首行'),
      HelpOption('--body B', '新的完整正文'),
      HelpOption('--body-file F', '从文件读；`-` 表示 stdin'),
    ],
    examples: ['printf "# 新标题\\n全文…\\n" | lck note edit 我的外脑概况'],
    notes: ['覆盖整篇正文，不是追加；追加用 note append。'],
  ),
  CommandHelp(
    path: ['note', 'mv'],
    usage: 'note mv <ID|关键词> [--folder F]',
    summary: '移动笔记；省略 --folder 表示移到根目录',
    tier: CommandTier.localWrite,
    options: [HelpOption('--folder F', '目标文件夹（名称或 ID）')],
    examples: ['lck note mv 调研纪要 --folder 工作台', 'lck note mv 调研纪要'],
    notes: ['省略 --folder 是移到根目录，不是「保持不动」。'],
  ),
  CommandHelp(
    path: ['note', 'rm'],
    usage: 'note rm <ID|关键词>',
    summary: '移入回收站（可 note restore 恢复）',
    tier: CommandTier.localWrite,
    examples: ['lck note rm 过期草稿'],
  ),
  CommandHelp(
    path: ['note', 'restore'],
    usage: 'note restore <ID|关键词>',
    summary: '从回收站恢复',
    tier: CommandTier.localWrite,
    examples: ['lck note restore 过期草稿'],
  ),
  CommandHelp(
    path: ['note', 'purge'],
    usage: 'note purge <ID|关键词> --yes',
    summary: '永久删除（不可恢复，必须 --yes）',
    tier: CommandTier.irreversible,
    flags: [HelpFlag('--yes', '确认永久删除；缺少时用法错误')],
    examples: ['lck note purge 过期草稿 --yes'],
    notes: ['不可恢复。用户未明确要求永久删除时，一律用 note rm（回收站）。'],
  ),
  CommandHelp(
    path: ['task'],
    usage: 'task <子命令> [选项]',
    summary: 'Markdown 待办（`- [ ]`）的汇总与勾选',
    defaultSubcommand: 'list',
    examples: ['lck task list --json', 'lck task done "离线模型部署"'],
  ),
  CommandHelp(
    path: ['task', 'list'],
    usage: 'task list [--all] [--note X]',
    summary: '汇总待办；默认只列未完成',
    options: [HelpOption('--note X', '只列该笔记内的待办（ID 或关键词）')],
    flags: [HelpFlag('--all', '包含已完成待办')],
    examples: ['lck task list --json', 'lck task list --all'],
  ),
  CommandHelp(
    path: ['task', 'add'],
    usage: 'task add "<文本>" [--note X] [--folder F]',
    summary: '新增待办（默认写入「待办清单」笔记）',
    tier: CommandTier.localWrite,
    options: [
      HelpOption('--note X', '写入指定笔记（ID 或关键词）'),
      HelpOption('--folder F', '「待办清单」所在文件夹（名称或 ID）'),
    ],
    examples: ['lck task add "读完今天的信息流"'],
  ),
  CommandHelp(
    path: ['task', 'done'],
    usage: 'task done <关键词> [--note X]',
    summary: '勾选唯一匹配的未完成待办',
    tier: CommandTier.localWrite,
    options: [HelpOption('--note X', '只在指定笔记内查找（ID 或关键词）')],
    examples: ['lck task done "离线模型部署"', 'lck task done "第 1 章" --note "本周待办"'],
    notes: ['命中多个未完成待办会报错并列出候选，此时用更精确的关键词或 --note。'],
  ),
];

/// 精确匹配命令路径；无匹配返回 null。
CommandHelp? exactCommandHelp(List<String> path) {
  for (final entry in kCommandHelps) {
    if (entry.path.length != path.length) continue;
    if (_isPrefix(entry.path, path)) return entry;
  }
  return null;
}

/// 渲染全局帮助：只列叶子命令的扁平索引（命令组在结尾一行提示）。
String renderGlobalHelp(String version) {
  final leaves = [
    for (final entry in kCommandHelps)
      if (entry.path.isNotEmpty && !entry.isGroup) entry,
  ];
  final groups = [
    for (final entry in kCommandHelps)
      if (entry.isGroup) entry.path.join(' '),
  ];

  final buffer = StringBuffer()
    ..writeln('lck $version —— Little Check 本地命令行工具')
    ..writeln()
    ..writeln('用法：lck <命令> [选项]')
    ..writeln()
    ..writeln('全局选项：')
    ..writeln('  --data-dir <路径>   指定数据目录（默认读 bootstrap，可用 `lck status` 查看）')
    ..writeln('  --json              输出 JSON（单条=对象，多条=数组，空=[]）')
    ..writeln('  --help, -h          显示帮助')
    ..writeln('  --version           显示版本');

  void section(String title, bool Function(CommandHelp) keep) {
    final rows = [
      for (final e in leaves)
        if (keep(e)) e,
    ];
    if (rows.isEmpty) return;
    buffer
      ..writeln()
      ..writeln('$title：');
    for (final entry in rows) {
      buffer.writeln(_indexLine(entry));
    }
  }

  section('只读命令', (e) => e.tier == CommandTier.readOnly);
  section('写入命令（可恢复）', (e) => e.tier == CommandTier.localWrite);
  section('不可逆命令', (e) => e.tier == CommandTier.irreversible);

  buffer
    ..writeln()
    ..writeln('命令组：${groups.join(' / ')} —— 用 `lck <组> --help` 查看子命令与选项。')
    ..writeln()
    ..writeln('写入正文为纯 markdown 透传，内容由调用方决定；未提供 --body/--body-file')
    ..writeln('且 stdin 非终端时，从 stdin 读取正文。')
    ..writeln()
    ..writeln('帮助：`lck help [命令...]` 与 `lck <命令> --help` 等价。')
    ..writeln()
    ..writeln('退出码：0 成功 / 1 运行时失败 / 2 用法错误');

  return buffer.toString();
}

const _indexColumn = 24;

/// 全局索引里的一行：`名字<对齐>说明`。
String _indexLine(CommandHelp entry) {
  final name = entry.indexLabel;
  final pad = name.length >= _indexColumn - 2
      ? '\n${' ' * _indexColumn}'
      : ' ' * (_indexColumn - name.length);
  return '  $name$pad${entry.summary}';
}

/// 渲染单个命令或命令组的帮助。
String renderCommandHelp(CommandHelp entry, String version) {
  final buffer = StringBuffer()
    ..writeln('lck ${entry.path.join(' ')} —— ${entry.summary}')
    ..writeln()
    ..writeln('用法：lck ${entry.usage}');

  if (entry.isGroup) {
    buffer
      ..writeln()
      ..writeln('子命令：');
    for (final child in entry.children) {
      final name = child.path.sublist(entry.path.length).join(' ');
      final pad = name.length >= 22
          ? '\n${' ' * 24}'
          : ' ' * (22 - name.length);
      buffer.writeln('  $name$pad${child.summary}');
    }
    if (entry.defaultSubcommand != null) {
      buffer.writeln('  （不带子命令时默认执行 ${entry.defaultSubcommand}）');
    }
  }

  if (entry.options.isNotEmpty || entry.flags.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('选项：');
    for (final option in entry.options) {
      buffer.writeln('  ${_pad(option.flag, 18)}${option.description}');
    }
    for (final flag in entry.flags) {
      buffer.writeln('  ${_pad(flag.name, 18)}${flag.description}');
    }
  }

  buffer
    ..writeln()
    ..writeln('通用选项：')
    ..writeln('  ${_pad('--json', 18)}输出 JSON（单条=对象，多条=数组，空=[]）')
    ..writeln('  ${_pad('--help, -h', 18)}显示本${entry.isGroup ? '组' : '命令'}帮助');

  if (entry.examples.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('示例：');
    for (final example in entry.examples) {
      buffer.writeln('  $example');
    }
  }

  if (entry.notes.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('说明：');
    for (final note in entry.notes) {
      buffer.writeln('  - $note');
    }
  }

  if (entry.isGroup) {
    buffer
      ..writeln()
      ..writeln('用 `lck ${entry.path.join(' ')} <子命令> --help` 查看单个子命令。');
  }

  buffer
    ..writeln()
    ..writeln('退出码：0 成功 / 1 运行时失败 / 2 用法错误');

  return buffer.toString();
}

/// 左侧对齐到 [width] 列；超长则换行缩进。
String _pad(String text, int width) => text.length >= width - 2
    ? '$text\n${' ' * width}'
    : '$text${' ' * (width - text.length)}';
