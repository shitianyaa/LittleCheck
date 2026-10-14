// lck —— Little Check 的本地命令行工具（demo）
//
// 目标：让本机 Agent 直接读写 Little Check 的本地数据（笔记 / 文件夹 / 待办），
// 复用 App 的 LocalStore，读写同一份 notebook.json 与 notes/*.md。
//
// 调用方式（务必用 `dart bin/lck.dart`，不要用 `dart run`——后者会触发
// Flutter 插件的 native-asset hook，在含空格的路径下会失败）：
//   dart bin/lck.dart status
//   dart bin/lck.dart note list --json
//   echo "# 标题\n正文" | dart bin/lck.dart note new --folder 工作台
//
// 约定：
//   - 默认输出人类可读；加 --json 输出结构化（单条=对象，多条=数组，空=[]）。
//   - 退出码：0 成功 / 1 运行时失败 / 2 用法错误。
//   - 写入命令是纯 markdown 透传：正文原样落盘，内容由调用方（Agent）决定。
//   - 不触碰信息流、AI 密钥、同步状态；删除只进回收站，永久删除需 --yes。
//   - 帮助文本是数据，见 bin/lck_help.dart；`lck <命令> --help` 是命令语义真源。
//   - 构建信息由 bin/build_lck.ps1 通过 -D 注入；未注入时为 dev 构建。

import 'dart:convert';
import 'dart:io';

import 'package:little_check/data_location.dart';
import 'package:little_check/storage.dart';
import 'package:little_check/tasks.dart';

import 'lck_help.dart';

/// 构建期注入（bin/build_lck.ps1 用 `dart compile exe -D` 传入）。
const _version = String.fromEnvironment('LCK_VERSION', defaultValue: 'dev');
const _commit = String.fromEnvironment('LCK_COMMIT', defaultValue: 'unknown');
const _buildDate = String.fromEnvironment(
  'LCK_BUILD_DATE',
  defaultValue: 'unknown',
);

/// `lck version <v>`；dev 构建补 commit 与构建时间。
/// 版本号始终是 `version` 后的第一个 token，skill 的版本配对检查按此解析。
String _versionLine() => _version == 'dev'
    ? 'lck version dev (commit $_commit, built $_buildDate)'
    : 'lck version $_version';

/// 用法错误：参数不合法，退出码 2。
class UsageException implements Exception {
  const UsageException(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<void> main(List<String> argv) async {
  stdout.encoding = utf8;
  stderr.encoding = utf8;
  try {
    final code = await _run(argv);
    exitCode = code;
  } on UsageException catch (e) {
    stderr.writeln('用法错误：${e.message}');
    exitCode = 2;
  } catch (e) {
    stderr.writeln('错误：$e');
    exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// 参数解析
// ---------------------------------------------------------------------------

const _flags = {
  '--json',
  '--help',
  '-h',
  '--trash',
  '--all',
  '--yes',
  '--version',
};
const _options = {
  '--data-dir',
  '--folder',
  '--note',
  '--title',
  '--body',
  '--body-file',
};

class _Args {
  _Args(this.positional, this.options, this.flags);

  final List<String> positional;
  final Map<String, String> options;
  final Set<String> flags;

  String? opt(String name) => options[name];
  bool has(String flag) => flags.contains(flag);

  static _Args parse(List<String> raw) {
    final positional = <String>[];
    final options = <String, String>{};
    final flags = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final token = raw[i];
      if (!token.startsWith('-')) {
        positional.add(token);
        continue;
      }
      final eq = token.indexOf('=');
      final name = eq == -1 ? token : token.substring(0, eq);
      if (_flags.contains(name)) {
        if (eq != -1) throw UsageException('$name 不接受取值');
        flags.add(name);
      } else if (_options.contains(name)) {
        if (eq != -1) {
          options[name] = token.substring(eq + 1);
        } else {
          if (i + 1 >= raw.length) throw UsageException('$name 缺少取值');
          options[name] = raw[++i];
        }
      } else {
        throw UsageException('未知选项 $token');
      }
    }
    return _Args(positional, options, flags);
  }
}

// ---------------------------------------------------------------------------
// 数据目录解析
//
// 优先级：--data-dir / LCK_DATA_DIR > bootstrap > 默认目录。
// 除显式覆盖外，定位逻辑与 App 共用 lib/data_location.dart，避免两处漂移。
// ---------------------------------------------------------------------------

Future<Directory> _resolveDataDir(_Args args) async {
  final explicit =
      args.opt('--data-dir') ?? Platform.environment['LCK_DATA_DIR'];
  if (explicit != null && explicit.trim().isNotEmpty) {
    final dir = Directory(explicit.trim()).absolute;
    if (!await dir.exists()) {
      throw UsageException('指定的数据目录不存在：${dir.path}');
    }
    return dir;
  }
  return resolveDataDirectory(_supportDirectory());
}

/// App 的 application support 目录（与 path_provider 在 Windows 上的结果一致）：
/// %APPDATA%\dev.littlecheck\little_check。
Directory _supportDirectory() {
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) {
      throw const FormatException('找不到 APPDATA 环境变量');
    }
    return Directory(
      '$appData${Platform.pathSeparator}dev.littlecheck${Platform.pathSeparator}little_check',
    );
  }
  final home = Platform.environment['HOME'] ?? '';
  return Directory('$home/.local/share/dev.littlecheck/little_check');
}

// ---------------------------------------------------------------------------
// 命令分发
// ---------------------------------------------------------------------------

/// 沿命令树逐级下降解析帮助路径。
///
/// 走到一个**命令组**后遇到不认识的 token，说明这是未知子命令
/// （`lck note bogus --help` → 用法错误，退出码 2），而不是静默回退到父组帮助。
/// 走到**叶子命令**后剩余的 token 是普通参数，忽略（`lck note show 关键词 --help`
/// 仍然给出 `note show` 的帮助）。
CommandHelp _resolveHelpPath(List<String> positional) {
  CommandHelp? current;
  for (var i = 0; i < positional.length; i++) {
    final entry = exactCommandHelp(positional.sublist(0, i + 1));
    if (entry != null) {
      current = entry;
      continue;
    }
    if (current != null && current.isGroup) {
      throw UsageException('未知子命令 ${positional.sublist(0, i + 1).join(' ')}');
    }
    break;
  }
  if (current == null) {
    throw UsageException('未知命令 ${positional.join(' ')}（试试 lck help）');
  }
  return current;
}

/// 把命令组调用解析到实际执行的子命令上。
///
/// `lck note --trash` 实际执行的是 `note list`，校验必须按 list 的声明来。
CommandHelp? _effectiveCommand(String group, String? sub) {
  if (sub != null) return exactCommandHelp([group, sub]);
  final entry = exactCommandHelp([group]);
  final fallback = entry?.defaultSubcommand;
  if (fallback == null) return entry;
  return exactCommandHelp([group, fallback]) ?? entry;
}

/// 校验参数是否被该命令接受。
///
/// 每个命令只接受自己声明的选项与标志（外加全局项）。未声明的一律用法错误，
/// 而不是静默忽略——静默忽略会让调用方以为参数生效了。
/// 未知命令不在这里报错，交给分发处给出更准确的文案。
void _validateArgs(_Args args, String group, String? sub) {
  final entry = _effectiveCommand(group, sub);
  if (entry == null) return;
  final path = entry.path.join(' ');
  final allowedOptions = {...kGlobalOptionNames, ...entry.acceptedOptionNames};
  final allowedFlags = {...kGlobalFlagNames, ...entry.acceptedFlagNames};
  for (final name in [...args.options.keys, ...args.flags]) {
    if (allowedOptions.contains(name) || allowedFlags.contains(name)) continue;
    throw UsageException('$path 不接受 $name；用 `lck $path --help` 查看可用选项');
  }
}

Future<int> _run(List<String> argv) async {
  final args = _Args.parse(argv);
  if (args.has('--version')) {
    stdout.writeln(_versionLine());
    return 0;
  }

  // help 分发：`lck help [路径]` 与 `lck <路径> --help` 等价。
  // 不依赖数据目录，先于任何 IO 处理。
  final helpTarget =
      args.positional.isNotEmpty && args.positional.first == 'help'
      ? args.positional.sublist(1)
      : null;
  if (helpTarget != null) {
    if (helpTarget.isEmpty) {
      stdout.write(renderGlobalHelp(_version));
      return 0;
    }
    stdout.write(renderCommandHelp(_resolveHelpPath(helpTarget), _version));
    return 0;
  }

  if (args.positional.isEmpty) {
    stdout.write(renderGlobalHelp(_version));
    return 0;
  }

  if (args.has('--help') || args.has('-h')) {
    stdout.write(
      renderCommandHelp(_resolveHelpPath(args.positional), _version),
    );
    return 0;
  }

  final group = args.positional.first;
  final sub = args.positional.length > 1 ? args.positional[1] : null;
  final rest = args.positional.skip(2).toList();
  final json = args.has('--json');

  // 参数校验先于任何 IO：用法错误不该依赖数据目录能否打开。
  _validateArgs(args, group, sub);

  final dir = await _resolveDataDir(args);
  final store = LocalStore(dir);
  await store.init();

  switch (group) {
    case 'status':
      return _cmdStatus(store, dir, json);
    case 'today':
      return _cmdToday(store, json);
    case 'folder':
      return _cmdFolder(store, sub, rest, args, json);
    case 'note':
      return _cmdNote(store, sub, rest, args, json);
    case 'task':
      return _cmdTask(store, sub, rest, args, json);
    default:
      throw UsageException('未知命令 $group（试试 lck help）');
  }
}

// ---------------------------------------------------------------------------
// status / today
// ---------------------------------------------------------------------------

Future<int> _cmdStatus(LocalStore store, Directory dir, bool json) async {
  final live = await store.loadNotes();
  final trash = await store.loadNotes(trash: true);
  if (json) {
    _emitJson({
      'dataDir': dir.path,
      'folders': store.folders.length,
      'notes': live.length,
      'trash': trash.length,
      'noteTombstones': store.noteTombstones.length,
      'folderTombstones': store.folderTombstones.length,
    });
    return 0;
  }
  stdout.writeln('数据目录：${dir.path}');
  stdout.writeln('文件夹：${store.folders.length}');
  stdout.writeln('笔记：${live.length}（回收站 ${trash.length}）');
  stdout.writeln(
    '删除标记：笔记 ${store.noteTombstones.length} / 文件夹 ${store.folderTombstones.length}',
  );
  return 0;
}

Future<int> _cmdToday(LocalStore store, bool json) async {
  final raw = store.settings['dailyTracker'];
  final today = _todayString();
  Map<String, dynamic> data = {};
  var fresh = true;
  if (raw is Map && raw['date'] == today) {
    data = Map<String, dynamic>.from(raw);
    fresh = false;
  }
  final summary = {
    'date': today,
    'hasActivityToday': !fresh,
    'opens': fresh ? 0 : (data['opens'] as num?)?.toInt() ?? 0,
    'feedReads': fresh ? 0 : (data['feedReads'] as num?)?.toInt() ?? 0,
    'aiTranslates': fresh ? 0 : (data['aiTranslates'] as num?)?.toInt() ?? 0,
    'aiSummaries': fresh ? 0 : (data['aiSummaries'] as num?)?.toInt() ?? 0,
    'wordsAdded': fresh ? 0 : (data['wordsAdded'] as num?)?.toInt() ?? 0,
    'wordsDeleted': fresh ? 0 : (data['wordsDeleted'] as num?)?.toInt() ?? 0,
    'tasksCompleted': fresh
        ? 0
        : (data['tasksCompleted'] as num?)?.toInt() ?? 0,
    'hasSavedToday': !fresh && data['hasSavedToday'] == true,
  };
  if (json) {
    _emitJson(summary);
    return 0;
  }
  stdout.writeln('日期：${summary['date']}');
  stdout.writeln('应用活跃：${summary['opens']} 次');
  stdout.writeln('信息流阅读：${summary['feedReads']} 篇');
  stdout.writeln(
    'AI 调用：${(summary['aiTranslates'] as int) + (summary['aiSummaries'] as int)} 次（翻译 ${summary['aiTranslates']} · 总结 ${summary['aiSummaries']}）',
  );
  stdout.writeln(
    '笔记字数：+${summary['wordsAdded']} / -${summary['wordsDeleted']}',
  );
  stdout.writeln('完成待办：${summary['tasksCompleted']} 项');
  stdout.writeln('今日回顾：${summary['hasSavedToday'] == true ? '已归档' : '未归档'}');
  return 0;
}

// ---------------------------------------------------------------------------
// folder
// ---------------------------------------------------------------------------

Future<int> _cmdFolder(
  LocalStore store,
  String? sub,
  List<String> rest,
  _Args args,
  bool json,
) async {
  switch (sub) {
    case 'list':
    case null:
      final folders = store.folders;
      final counts = <String, int>{for (final id in folders.keys) id: 0};
      for (final note in await store.loadNotes()) {
        final folderId = note.folderId;
        if (folderId != null && counts.containsKey(folderId)) {
          counts[folderId] = counts[folderId]! + 1;
        }
      }
      if (json) {
        _emitJson([
          for (final e in folders.entries)
            {'id': e.key, 'name': e.value, 'notes': counts[e.key] ?? 0},
        ]);
        return 0;
      }
      if (folders.isEmpty) {
        stdout.writeln('(没有文件夹)');
        return 0;
      }
      for (final e in folders.entries) {
        stdout.writeln('${e.key}\t${e.value}\t${counts[e.key] ?? 0} 篇');
      }
      return 0;

    case 'new':
      if (rest.isEmpty) throw const UsageException('folder new 需要一个名称');
      final name = rest.join(' ');
      final id = store.newNoteId();
      await store.putFolder(id, name);
      if (json) {
        _emitJson({'id': id, 'name': name});
      } else {
        stdout.writeln('已创建文件夹：$name（$id）');
      }
      return 0;

    case 'rm':
      if (rest.isEmpty) throw const UsageException('folder rm 需要一个名称或 ID');
      final ref = rest.join(' ');
      final id = _resolveFolder(store, ref);
      await store.deleteFolder(id, trashContents: true);
      if (json) {
        _emitJson({'id': id, 'deleted': true});
      } else {
        stdout.writeln('已删除文件夹（内含笔记移入回收站）：$ref');
      }
      return 0;

    default:
      throw UsageException('未知子命令 folder $sub');
  }
}

String _resolveFolder(LocalStore store, String ref) {
  final folders = store.folders;
  if (folders.containsKey(ref)) return ref;
  final matches = folders.entries.where((e) => e.value == ref.trim()).toList();
  if (matches.length == 1) return matches.first.key;
  if (matches.isEmpty) throw UsageException('找不到文件夹：$ref');
  throw UsageException('文件夹名称不唯一，请用 ID：$ref');
}

// ---------------------------------------------------------------------------
// note
// ---------------------------------------------------------------------------

Future<int> _cmdNote(
  LocalStore store,
  String? sub,
  List<String> rest,
  _Args args,
  bool json,
) async {
  switch (sub) {
    case 'list':
    case null:
      return _noteList(store, args, json);
    case 'show':
      return _noteShow(store, rest, json);
    case 'search':
      return _noteSearch(store, rest, json);
    case 'new':
      return _noteNew(store, args, json);
    case 'append':
      return _noteWrite(store, rest, args, json, append: true);
    case 'edit':
      return _noteWrite(store, rest, args, json, append: false);
    case 'mv':
      return _noteMove(store, rest, args, json);
    case 'rm':
      return _noteTrash(store, rest, json, restore: false);
    case 'restore':
      return _noteTrash(store, rest, json, restore: true);
    case 'purge':
      return _notePurge(store, rest, args, json);
    default:
      throw UsageException('未知子命令 note $sub');
  }
}

Future<int> _noteList(LocalStore store, _Args args, bool json) async {
  final trash = args.has('--trash');
  var notes = await store.loadNotes(trash: trash);
  final folderRef = args.opt('--folder');
  if (folderRef != null) {
    final folderId = _resolveFolder(store, folderRef);
    notes = notes.where((n) => n.folderId == folderId).toList();
  }
  notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  final folders = store.folders;
  if (json) {
    _emitJson([for (final n in notes) _noteJson(n, folders)]);
    return 0;
  }
  if (notes.isEmpty) {
    stdout.writeln(trash ? '(回收站为空)' : '(没有笔记)');
    return 0;
  }
  for (final n in notes) {
    final folder = n.folderId == null ? '' : folders[n.folderId] ?? '';
    stdout.writeln(
      '${n.id}\t${_date(n.updatedAt)}\t${folder.isEmpty ? '-' : folder}\t${n.title}',
    );
  }
  return 0;
}

Future<int> _noteShow(LocalStore store, List<String> rest, bool json) async {
  if (rest.isEmpty) throw const UsageException('note show 需要一个 ID 或关键词');
  final note = await _findNote(store, rest.join(' '));
  if (json) {
    _emitJson({..._noteJson(note, store.folders), 'content': note.content});
    return 0;
  }
  stdout.write(note.content);
  if (!note.content.endsWith('\n')) stdout.writeln();
  return 0;
}

Future<int> _noteSearch(LocalStore store, List<String> rest, bool json) async {
  if (rest.isEmpty) throw const UsageException('note search 需要一个关键词');
  final keyword = rest.join(' ');
  final needle = keyword.toLowerCase();
  final notes =
      (await store.loadNotes())
          .where((n) => n.content.toLowerCase().contains(needle))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  if (json) {
    _emitJson([for (final n in notes) _noteJson(n, store.folders)]);
    return 0;
  }
  if (notes.isEmpty) {
    stdout.writeln('(没有匹配的笔记)');
    return 0;
  }
  for (final n in notes) {
    stdout.writeln('${n.id}\t${n.title}');
  }
  return 0;
}

Future<int> _noteNew(LocalStore store, _Args args, bool json) async {
  final title = args.opt('--title');
  final body = await _readBody(args);
  final content = _composeContent(title, body);
  final id = store.newNoteId();
  final folderRef = args.opt('--folder');
  final folderId = folderRef == null ? null : _resolveFolder(store, folderRef);
  await store.saveNote(id, content);
  await store.moveNote(id, folderId);
  final note = Note(
    id: id,
    content: content,
    updatedAt: await store.noteFile(id).lastModified(),
    folderId: folderId,
  );
  if (json) {
    _emitJson(_noteJson(note, store.folders));
  } else {
    stdout.writeln('已新建笔记：${note.title}（$id）');
  }
  return 0;
}

Future<int> _noteWrite(
  LocalStore store,
  List<String> rest,
  _Args args,
  bool json, {
  required bool append,
}) async {
  if (rest.isEmpty) throw const UsageException('需要笔记 ID 或关键词');
  // 注：--title 在 append 上由 _validateArgs 按命令声明拒绝，这里不再单独判。
  final note = await _findNote(store, rest.join(' '));
  final body = await _readBody(args);
  if (body.isEmpty) throw const UsageException('正文为空（用 --body 或 stdin 提供）');
  final content = append
      ? _appendContent(note.content, body)
      : _composeContent(args.opt('--title'), body);
  await store.saveNote(note.id, content);
  if (json) {
    _emitJson({
      'id': note.id,
      'title': _titleOf(content),
      'bytes': utf8.encode(content).length,
    });
  } else {
    stdout.writeln(
      '${append ? '已追加' : '已更新'}：${_titleOf(content)}（${note.id}）',
    );
  }
  return 0;
}

Future<int> _noteMove(
  LocalStore store,
  List<String> rest,
  _Args args,
  bool json,
) async {
  if (rest.isEmpty) throw const UsageException('note mv 需要一个 ID 或关键词');
  final note = await _findNote(store, rest.join(' '));
  final folderRef = args.opt('--folder');
  final folderId = folderRef == null ? null : _resolveFolder(store, folderRef);
  await store.moveNote(note.id, folderId);
  if (json) {
    _emitJson({'id': note.id, 'folderId': folderId});
  } else {
    stdout.writeln('已移动：${note.title} → ${folderRef ?? '（根目录）'}');
  }
  return 0;
}

Future<int> _noteTrash(
  LocalStore store,
  List<String> rest,
  bool json, {
  required bool restore,
}) async {
  if (rest.isEmpty) throw const UsageException('需要笔记 ID 或关键词');
  final ref = rest.join(' ');
  final note = await _findNote(store, ref, trash: restore ? true : false);
  await store.trashNote(note.id, restore: restore);
  if (json) {
    _emitJson({'id': note.id, 'restored': restore});
  } else {
    stdout.writeln(restore ? '已恢复：${note.title}' : '已移入回收站：${note.title}');
  }
  return 0;
}

Future<int> _notePurge(
  LocalStore store,
  List<String> rest,
  _Args args,
  bool json,
) async {
  if (rest.isEmpty) throw const UsageException('note purge 需要一个 ID 或关键词');
  if (!args.has('--yes')) {
    throw const UsageException('永久删除不可恢复，请加 --yes 确认');
  }
  final note = await _findNote(store, rest.join(' '), trash: true);
  await store.deleteNotePermanently(note.id);
  if (json) {
    _emitJson({'id': note.id, 'purged': true});
  } else {
    stdout.writeln('已永久删除：${note.title}');
  }
  return 0;
}

// ---------------------------------------------------------------------------
// task
// ---------------------------------------------------------------------------

Future<int> _cmdTask(
  LocalStore store,
  String? sub,
  List<String> rest,
  _Args args,
  bool json,
) async {
  switch (sub) {
    case 'list':
    case null:
      return _taskList(store, args, json);
    case 'add':
      return _taskAdd(store, rest, args, json);
    case 'done':
      return _taskDone(store, rest, args, json);
    default:
      throw UsageException('未知子命令 task $sub');
  }
}

Future<int> _taskList(LocalStore store, _Args args, bool json) async {
  final all = args.has('--all');
  final noteRef = args.opt('--note');
  var notes = await store.loadNotes();
  if (noteRef != null) {
    final target = await _findNote(store, noteRef);
    notes = notes.where((n) => n.id == target.id).toList();
  }
  final rows = <Map<String, dynamic>>[];
  for (final note in notes) {
    for (final task in MarkdownTasks.parse(note.content)) {
      if (!all && task.checked) continue;
      rows.add({
        'noteId': note.id,
        'noteTitle': note.title,
        'checked': task.checked,
        'text': _taskText(note.content, task.offset),
      });
    }
  }
  if (json) {
    _emitJson(rows);
    return 0;
  }
  if (rows.isEmpty) {
    stdout.writeln('(没有待办)');
    return 0;
  }
  for (final r in rows) {
    stdout.writeln(
      '${r['checked'] == true ? '[x]' : '[ ]'}\t${r['text']}\t← ${r['noteTitle']}',
    );
  }
  return 0;
}

Future<int> _taskAdd(
  LocalStore store,
  List<String> rest,
  _Args args,
  bool json,
) async {
  if (rest.isEmpty) throw const UsageException('task add 需要待办文本');
  final text = rest.join(' ').trim();
  final noteRef = args.opt('--note');
  Note target;
  if (noteRef != null) {
    target = await _findNote(store, noteRef);
  } else {
    target = await _findOrCreateTaskNote(store, args.opt('--folder'));
  }
  final content = _appendContent(target.content, '- [ ] $text');
  await store.saveNote(target.id, content);
  if (json) {
    _emitJson({'noteId': target.id, 'text': text});
  } else {
    stdout.writeln('已添加待办：$text ← ${target.title}');
  }
  return 0;
}

Future<int> _taskDone(
  LocalStore store,
  List<String> rest,
  _Args args,
  bool json,
) async {
  if (rest.isEmpty) throw const UsageException('task done 需要待办关键词');
  final keyword = rest.join(' ');
  final needle = keyword.toLowerCase();
  final noteRef = args.opt('--note');
  var notes = await store.loadNotes();
  if (noteRef != null) {
    final target = await _findNote(store, noteRef);
    notes = notes.where((n) => n.id == target.id).toList();
  }
  final hits = <({Note note, MarkdownTask task})>[];
  for (final note in notes) {
    for (final task in MarkdownTasks.parse(note.content)) {
      if (task.checked) continue;
      if (_taskText(note.content, task.offset).toLowerCase().contains(needle)) {
        hits.add((note: note, task: task));
      }
    }
  }
  if (hits.isEmpty) throw UsageException('找不到匹配的未完成待办：$keyword');
  if (hits.length > 1) {
    final list = hits
        .map(
          (h) =>
              '  - ${_taskText(h.note.content, h.task.offset)}（${h.note.title}）',
        )
        .join('\n');
    throw UsageException('匹配到多个待办，请用更精确的关键词或 --note 指定笔记：\n$list');
  }
  final hit = hits.first;
  final updated = MarkdownTasks.toggle(hit.note.content, hit.task.offset);
  await store.saveNote(hit.note.id, updated);
  if (json) {
    _emitJson({
      'noteId': hit.note.id,
      'text': _taskText(hit.note.content, hit.task.offset),
    });
  } else {
    stdout.writeln('已完成：${_taskText(hit.note.content, hit.task.offset)}');
  }
  return 0;
}

Future<Note> _findOrCreateTaskNote(LocalStore store, String? folderRef) async {
  final folderId = folderRef == null ? null : _resolveFolder(store, folderRef);
  final notes = await store.loadNotes();
  for (final n in notes) {
    if (n.title == '待办清单' && n.folderId == folderId) return n;
  }
  final id = store.newNoteId();
  const content = '# 待办清单\n\n';
  await store.saveNote(id, content);
  await store.moveNote(id, folderId);
  return Note(
    id: id,
    content: content,
    updatedAt: DateTime.now(),
    folderId: folderId,
  );
}

// ---------------------------------------------------------------------------
// 共享辅助
// ---------------------------------------------------------------------------

/// 按 ID 或关键词唯一定位一篇笔记。
Future<Note> _findNote(
  LocalStore store,
  String ref, {
  bool trash = false,
}) async {
  final notes = await store.loadNotes(trash: trash);
  final byId = notes.where((n) => n.id == ref).toList();
  if (byId.length == 1) return byId.first;
  final needle = ref.toLowerCase();
  final matches = notes.where((n) {
    return n.title.toLowerCase().contains(needle) ||
        n.content.toLowerCase().contains(needle);
  }).toList();
  if (matches.length == 1) return matches.first;
  if (matches.isEmpty) throw UsageException('找不到笔记：$ref');
  final list = matches
      .take(10)
      .map((n) => '  - ${n.title}（${n.id}）')
      .join('\n');
  throw UsageException('匹配到多篇笔记，请用 ID 或更精确的关键词：\n$list');
}

/// 从 stdin / --body / --body-file 读取 markdown 正文（原样透传）。
Future<String> _readBody(_Args args) async {
  final inline = args.opt('--body');
  if (inline != null) return inline;
  final fileRef = args.opt('--body-file');
  if (fileRef != null) {
    if (fileRef == '-') return await _readStdin();
    final file = File(fileRef);
    if (!await file.exists()) throw UsageException('找不到文件：$fileRef');
    return file.readAsString();
  }
  if (!stdin.hasTerminal) return await _readStdin();
  return '';
}

Future<String> _readStdin() async {
  final buffer = StringBuffer();
  await for (final chunk in stdin.transform(utf8.decoder)) {
    buffer.write(chunk);
  }
  return buffer.toString();
}

/// 组装笔记正文。
///
/// 显式传入的 --title 与正文首行标题冲突时是**用法错误**，不静默丢弃参数：
/// 静默丢弃会让调用方以为标题生效了，而落盘的是另一份内容。
/// 组装笔记正文。
///
/// 显式传入的 --title 与正文首行标题冲突时是**用法错误**，不静默丢弃参数：
/// 静默丢弃会让调用方以为标题生效了，而落盘的是另一份内容。
/// 同理，传了但全空白的 --title 也是用法错误，而不是当作没传。
String _composeContent(String? title, String body) {
  if (title == null) return body;
  final trimmedTitle = title.trim();
  if (trimmedTitle.isEmpty) {
    throw const UsageException('--title 不能为空；去掉 --title，或给出非空标题');
  }
  if (body.trimLeft().startsWith('#')) {
    throw const UsageException('正文自带标题行，与 --title 冲突；去掉 --title，或去掉正文首行标题');
  }
  final heading = '# $trimmedTitle';
  return body.isEmpty ? '$heading\n' : '$heading\n\n$body';
}

String _appendContent(String existing, String body) {
  if (existing.isEmpty) return body.endsWith('\n') ? body : '$body\n';
  // 保证追加内容与原文之间以空行分隔；不改动已有字符，只在其后补足换行。
  var prefix = existing;
  if (!prefix.endsWith('\n')) {
    prefix = '$prefix\n\n';
  } else if (!prefix.endsWith('\n\n')) {
    prefix = '$prefix\n';
  }
  final tail = body.endsWith('\n') ? body : '$body\n';
  return '$prefix$tail';
}

String _titleOf(String content) {
  final first = content
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .firstOrNull;
  if (first == null) return '未命名笔记';
  return first.replaceFirst(RegExp(r'^\s*#+\s*'), '').trim();
}

String _taskText(String source, int offset) {
  final lineStart = source.lastIndexOf('\n', offset) + 1;
  var lineEnd = source.indexOf('\n', offset);
  if (lineEnd == -1) lineEnd = source.length;
  final line = source.substring(lineStart, lineEnd);
  final close = line.indexOf(']');
  return close == -1 ? line.trim() : line.substring(close + 1).trim();
}

Map<String, dynamic> _noteJson(Note note, Map<String, String> folders) => {
  'id': note.id,
  'title': note.title,
  'folderId': note.folderId,
  'folder': note.folderId == null ? null : folders[note.folderId],
  'updatedAt': note.updatedAt.toUtc().toIso8601String(),
  'deletedAt': note.deletedAt?.toUtc().toIso8601String(),
  'excerpt': note.excerpt,
};

String _date(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${_two(local.month)}-${_two(local.day)} ${_two(local.hour)}:${_two(local.minute)}';
}

String _two(int value) => value.toString().padLeft(2, '0');

String _todayString() {
  final now = DateTime.now();
  return '${now.year}-${_two(now.month)}-${_two(now.day)}';
}

void _emitJson(Object? value) {
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(value));
}
