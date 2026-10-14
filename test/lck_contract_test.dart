// lck 的离线契约测试。
//
// 覆盖 bin/lck.dart 的对外契约：退出码（0/1/2）、子命令 --help、--json 形状、
// 写入副作用、安全边界（回收站 vs 永久删除）。
//
// 为什么起子进程而不是直接调函数：退出码本身就是契约的一部分，只有真实进程
// 能验证；stdin 与 stderr 的真实行为同理。
//
// 两条硬约束（都是实测踩出来的）：
//   1. 必须用 `dart bin/lck.dart`，不能用 `dart run` —— 项目路径含空格时
//      `dart run` 会触发 Flutter 插件的 native-asset hook 而失败。
//   2. 不能用 argv 传含换行的内容 —— Windows 上 bash/批处理转发参数时换行会
//      破坏参数（实测 dart.bat 的内部脚本文本会漏进参数）。正文一律走 stdin。
//
// 每个用例用独立的临时数据目录（--data-dir），绝不碰真实工作台数据。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 一次 lck 调用的结果。
class LckResult {
  LckResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  /// stdout + stderr，用于「错误信息出现在哪一路都行」的断言。
  String get combined => '$stdout\n$stderr';

  /// 解析 --json 输出。
  dynamic get json => jsonDecode(stdout);
}

/// 定位 dart 可执行文件。
///
/// 解析顺序：$FLUTTER_ROOT 下的 SDK > 从 Platform.resolvedExecutable 上溯。
/// 两处都找不到时**抛出并打印探测过的路径**，不静默跳过 —— 静默跳过会让契约
/// 测试变成永远通过的空壳。
String findDartExecutable() {
  final name = Platform.isWindows ? 'dart.exe' : 'dart';
  final tried = <String>[];

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    final candidate = [
      flutterRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      name,
    ].join(Platform.pathSeparator);
    if (File(candidate).existsSync()) return candidate;
    tried.add(candidate);
  }

  // flutter test 下 resolvedExecutable 是
  // <flutter>/bin/cache/artifacts/engine/<os>-<arch>/flutter_tester(.exe)，
  // 上溯 5 层即 Flutter 根。
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 8; i++) {
    final candidate = [
      dir.path,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      name,
    ].join(Platform.pathSeparator);
    if (File(candidate).existsSync()) return candidate;
    tried.add(candidate);
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }

  fail('找不到 dart 可执行文件。已探测：\n  ${tried.join('\n  ')}');
}

void main() {
  final dart = findDartExecutable();
  final repoRoot = Directory.current.path;
  final lckScript = [repoRoot, 'bin', 'lck.dart'].join(Platform.pathSeparator);

  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('lck_contract_');
  });

  tearDown(() {
    if (sandbox.existsSync()) {
      sandbox.deleteSync(recursive: true);
    }
  });

  /// 调用 lck。stdin 传 null 表示不写任何内容（管道立即关闭）。
  Future<LckResult> lck(
    List<String> args, {
    String? stdin,
    String? dataDir,
  }) async {
    final process = await Process.start(dart, [
      lckScript,
      '--data-dir',
      dataDir ?? sandbox.path,
      ...args,
    ], workingDirectory: repoRoot);
    final outFuture = process.stdout.transform(utf8.decoder).join();
    final errFuture = process.stderr.transform(utf8.decoder).join();
    if (stdin != null) {
      process.stdin.write(stdin);
    }
    try {
      await process.stdin.close();
    } on SocketException {
      // 进程已退出并关闭管道，忽略。
    }
    final code = await process.exitCode;
    return LckResult(code, await outFuture, await errFuture);
  }

  /// 用 stdin 建一篇笔记，返回其 id。
  Future<String> createNote(String content) async {
    final result = await lck(['note', 'new', '--json'], stdin: content);
    expect(result.exitCode, 0, reason: 'note new 失败：${result.combined}');
    return (result.json as Map<String, dynamic>)['id'] as String;
  }

  /// 数据目录下的笔记文件。
  File noteFile(String id) =>
      File([sandbox.path, 'notes', '$id.md'].join(Platform.pathSeparator));

  // -------------------------------------------------------------------------
  group('环境与用法', () {
    test('1. --version 打印版本行，退出码 0', () async {
      final result = await lck(['--version']);
      expect(result.exitCode, 0);
      expect(result.stdout.trim(), matches(RegExp(r'^lck version \S+')));
    });

    test('2. 无参数打印全局帮助，退出码 0', () async {
      final result = await lck([]);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('只读命令'));
      expect(result.stdout, contains('写入命令'));
      expect(result.stdout, contains('退出码'));
    });

    test('3. --help 打印全局帮助', () async {
      final result = await lck(['--help']);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('用法：lck <命令> [选项]'));
    });

    test('4. 未知命令退出码 2，错误在 stderr', () async {
      final result = await lck(['bogus']);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('未知命令'));
      expect(result.stdout, isEmpty);
    });

    test('5. 未知选项退出码 2', () async {
      final result = await lck(['note', 'list', '--nope']);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('未知选项'));
    });

    test('6. --data-dir 指向不存在的目录退出码 2', () async {
      final missing = [sandbox.path, 'nope'].join(Platform.pathSeparator);
      final result = await lck(['status'], dataDir: missing);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('数据目录不存在'));
    });
  });

  // -------------------------------------------------------------------------
  group('子命令 help', () {
    test('7. note --help 列出子命令', () async {
      final result = await lck(['note', '--help']);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('子命令'));
      for (final sub in ['list', 'show', 'new', 'append', 'purge']) {
        expect(result.stdout, contains(sub), reason: '缺少子命令 $sub');
      }
    });

    test('8. note new --help 给出用法与选项', () async {
      final result = await lck(['note', 'new', '--help']);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('用法：lck note new'));
      expect(result.stdout, contains('--title'));
      expect(result.stdout, contains('--body-file'));
      expect(result.stdout, contains('示例'));
    });

    test('9. folder --help 与 task --help', () async {
      final folder = await lck(['folder', '--help']);
      expect(folder.exitCode, 0);
      expect(folder.stdout, contains('用法：lck folder <子命令>'));

      final task = await lck(['task', '--help']);
      expect(task.exitCode, 0);
      expect(task.stdout, contains('用法：lck task <子命令>'));
    });

    test('10. help note new 与 note new --help 输出一致', () async {
      final viaHelp = await lck(['help', 'note', 'new']);
      final viaFlag = await lck(['note', 'new', '--help']);
      expect(viaHelp.exitCode, 0);
      expect(viaHelp.stdout, viaFlag.stdout);
    });

    test('11. 未知子命令加 --help 退出码 2（不回退到父组帮助）', () async {
      final result = await lck(['note', 'bogus', '--help']);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('未知子命令'));
      expect(result.stdout, isEmpty);
    });

    test('11b. 叶子命令后的额外 token 不当作子命令', () async {
      final result = await lck(['note', 'show', '关键词', '--help']);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('用法：lck note show'));
    });
  });

  // -------------------------------------------------------------------------
  group('读命令', () {
    test('12. 空库 status --json', () async {
      final result = await lck(['status', '--json']);
      expect(result.exitCode, 0);
      final data = result.json as Map<String, dynamic>;
      expect(data['folders'], 0);
      expect(data['notes'], 0);
      expect(data['trash'], 0);
      expect(data['dataDir'], sandbox.path);
    });

    test('13. 空库 note list --json 是空数组', () async {
      final result = await lck(['note', 'list', '--json']);
      expect(result.exitCode, 0);
      expect(result.stdout.trim(), '[]');
    });

    test('14. 空库 note list 是空提示', () async {
      final result = await lck(['note', 'list']);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('没有笔记'));
    });

    test('15. today --json 含完整字段', () async {
      final result = await lck(['today', '--json']);
      expect(result.exitCode, 0);
      final data = result.json as Map<String, dynamic>;
      expect(data['date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      // 空库下全部计数字段应为 0，而不是缺字段。
      expect(
        data.keys,
        containsAll(<String>[
          'date',
          'hasActivityToday',
          'opens',
          'feedReads',
          'aiTranslates',
          'aiSummaries',
          'wordsAdded',
          'wordsDeleted',
          'tasksCompleted',
          'hasSavedToday',
        ]),
      );
      expect(data['hasActivityToday'], isFalse);
      expect(data['opens'], 0);
      expect(data['tasksCompleted'], 0);
      expect(data['hasSavedToday'], isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('写命令与副作用', () {
    test('16. note new 落盘，内容与传入一致', () async {
      const content = '# 标题\n\n正文内容\n';
      final id = await createNote(content);
      expect(noteFile(id).existsSync(), isTrue, reason: '笔记文件未落盘');
      expect(noteFile(id).readAsStringSync(), content);

      final list = await lck(['note', 'list', '--json']);
      final notes = list.json as List<dynamic>;
      expect(notes.length, 1);
      expect((notes.first as Map<String, dynamic>)['title'], '标题');
    });

    test('17. --title 与普通正文合成标题行', () async {
      final result = await lck([
        'note',
        'new',
        '--title',
        '会议记录',
        '--json',
      ], stdin: '正文');
      expect(result.exitCode, 0);
      final id = (result.json as Map<String, dynamic>)['id'] as String;
      expect(noteFile(id).readAsStringSync(), '# 会议记录\n\n正文');
    });

    test('18. --title 与正文自带标题冲突时退出码 2 且不落盘', () async {
      final result = await lck([
        'note',
        'new',
        '--title',
        'T',
      ], stdin: '# B\n正文\n');
      expect(result.exitCode, 2);
      expect(result.stderr, contains('冲突'));

      final notesDir = Directory(
        [sandbox.path, 'notes'].join(Platform.pathSeparator),
      );
      final written = notesDir.existsSync()
          ? notesDir.listSync().whereType<File>().toList()
          : <File>[];
      expect(written, isEmpty, reason: '冲突时不应写入任何笔记文件');
    });

    test('18b. note append 不接受 --title', () async {
      final id = await createNote('# 标题\n正文\n');
      final result = await lck([
        'note',
        'append',
        id,
        '--title',
        'T',
      ], stdin: '追加\n');
      expect(result.exitCode, 2);
      expect(result.stderr, contains('--title'));
      expect(noteFile(id).readAsStringSync(), '# 标题\n正文\n');
    });

    test('19. note append 自动补空行分隔', () async {
      final id = await createNote('# 标题\n正文');
      final result = await lck(['note', 'append', id], stdin: '追加行\n');
      expect(result.exitCode, 0);
      expect(noteFile(id).readAsStringSync(), '# 标题\n正文\n\n追加行\n');
    });

    test('20. note edit 覆盖而非追加', () async {
      final id = await createNote('# 旧标题\n旧正文\n');
      final result = await lck(['note', 'edit', id], stdin: '# 新标题\n新正文\n');
      expect(result.exitCode, 0);
      expect(noteFile(id).readAsStringSync(), '# 新标题\n新正文\n');
    });

    test('21. note mv 移动与移回根目录', () async {
      final id = await createNote('# 笔记\n正文\n');
      await lck(['folder', 'new', '工作台']);

      final moved = await lck(['note', 'mv', id, '--folder', '工作台']);
      expect(moved.exitCode, 0);

      var list = await lck(['note', 'list', '--json']);
      var note = (list.json as List<dynamic>).first as Map<String, dynamic>;
      expect(note['folder'], '工作台');

      // 省略 --folder 表示移到根目录，不是「保持不动」。
      final back = await lck(['note', 'mv', id]);
      expect(back.exitCode, 0);

      list = await lck(['note', 'list', '--json']);
      note = (list.json as List<dynamic>).first as Map<String, dynamic>;
      expect(note['folderId'], isNull);
    });

    test('22. task add 默认创建并追加「待办清单」笔记', () async {
      final first = await lck(['task', 'add', '读完今天的信息流']);
      expect(first.exitCode, 0);

      final list = await lck(['note', 'list', '--json']);
      final notes = list.json as List<dynamic>;
      expect(notes.length, 1);
      expect((notes.first as Map<String, dynamic>)['title'], '待办清单');

      final second = await lck(['task', 'add', '第二条待办']);
      expect(second.exitCode, 0);
      // 复用同一篇，不新建。
      final again = await lck(['note', 'list', '--json']);
      expect((again.json as List<dynamic>).length, 1);
    });

    test('23. task list 默认只列未完成，--all 含已完成', () async {
      await lck(['task', 'add', '待办甲']);
      await lck(['task', 'add', '待办乙']);
      await lck(['task', 'done', '待办甲']);

      final open = await lck(['task', 'list', '--json']);
      expect(open.exitCode, 0);
      final openRows = open.json as List<dynamic>;
      expect(openRows.length, 1);
      expect((openRows.first as Map<String, dynamic>)['text'], '待办乙');

      final all = await lck(['task', 'list', '--all', '--json']);
      expect((all.json as List<dynamic>).length, 2);
    });

    test('24. task done 命中多个时退出码 2 并列出候选', () async {
      await lck(['task', 'add', '复习极限']);
      await lck(['task', 'add', '复习导数']);

      final result = await lck(['task', 'done', '复习']);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('复习极限'));
      expect(result.stderr, contains('复习导数'));
    });

    test('34. note new --body 落盘单行正文', () async {
      final result = await lck(['note', 'new', '--body', '单行正文', '--json']);
      expect(result.exitCode, 0);
      final id = (result.json as Map<String, dynamic>)['id'] as String;
      expect(noteFile(id).readAsStringSync(), '单行正文');
    });

    test('35. note new --body-file 从文件读正文', () async {
      final src = File([sandbox.path, 'src.md'].join(Platform.pathSeparator));
      src.writeAsStringSync('# 文件标题\n文件正文\n');

      final result = await lck([
        'note',
        'new',
        '--body-file',
        src.path,
        '--json',
      ]);
      expect(result.exitCode, 0);
      final id = (result.json as Map<String, dynamic>)['id'] as String;
      expect(noteFile(id).readAsStringSync(), '# 文件标题\n文件正文\n');
    });

    test('36. --body 优先于 stdin', () async {
      final result = await lck([
        'note',
        'new',
        '--body',
        '来自参数',
        '--json',
      ], stdin: '来自stdin\n');
      expect(result.exitCode, 0);
      final id = (result.json as Map<String, dynamic>)['id'] as String;
      expect(noteFile(id).readAsStringSync(), '来自参数');
    });

    test('37. --body-file - 读 stdin', () async {
      final result = await lck([
        'note',
        'new',
        '--body-file',
        '-',
        '--json',
      ], stdin: '# 管道\n正文\n');
      expect(result.exitCode, 0);
      final id = (result.json as Map<String, dynamic>)['id'] as String;
      expect(noteFile(id).readAsStringSync(), '# 管道\n正文\n');
    });

    test('38. --note 消解待办歧义', () async {
      final a = await createNote('# 笔记甲\n\n- [ ] 复习极限\n');
      final b = await createNote('# 笔记乙\n\n- [ ] 复习导数\n');

      // 关键词命中两篇 → 歧义
      final ambiguous = await lck(['task', 'done', '复习']);
      expect(ambiguous.exitCode, 2);

      // 用 --note 限定范围后唯一
      final resolved = await lck(['task', 'done', '复习', '--note', a]);
      expect(resolved.exitCode, 0);
      expect(noteFile(a).readAsStringSync(), contains('- [x] 复习极限'));
      expect(noteFile(b).readAsStringSync(), contains('- [ ] 复习导数'));
    });

    test('39. task add --note 写入指定笔记', () async {
      final id = await createNote('# 目标笔记\n\n');
      final result = await lck(['task', 'add', '新待办', '--note', id]);
      expect(result.exitCode, 0);
      expect(noteFile(id).readAsStringSync(), contains('- [ ] 新待办'));

      // 不应顺带创建「待办清单」
      final list = await lck(['note', 'list', '--json']);
      expect((list.json as List<dynamic>).length, 1);
    });

    test('40. task list --note 只列该笔记', () async {
      final a = await createNote('# 甲\n\n- [ ] 甲待办\n');
      await createNote('# 乙\n\n- [ ] 乙待办\n');

      final result = await lck(['task', 'list', '--note', a, '--json']);
      expect(result.exitCode, 0);
      final rows = result.json as List<dynamic>;
      expect(rows.length, 1);
      expect((rows.first as Map<String, dynamic>)['text'], '甲待办');
    });

    test('44. 空白 --title 退出码 2 且不落盘', () async {
      for (final blank in ['   ', '']) {
        final result = await lck([
          'note',
          'new',
          '--title',
          blank,
        ], stdin: '# B\n正文\n');
        expect(result.exitCode, 2, reason: '--title "$blank" 应被拒绝');
        expect(result.stderr, contains('不能为空'));
      }

      final notesDir = Directory(
        [sandbox.path, 'notes'].join(Platform.pathSeparator),
      );
      final written = notesDir.existsSync()
          ? notesDir.listSync().whereType<File>().toList()
          : <File>[];
      expect(written, isEmpty, reason: '空白 --title 不应写入任何笔记文件');
    });
  });

  // -------------------------------------------------------------------------
  group('安全边界', () {
    test('25. note rm 只进回收站', () async {
      final id = await createNote('# 过期草稿\n正文\n');
      final result = await lck(['note', 'rm', id]);
      expect(result.exitCode, 0);

      final live = await lck(['note', 'list', '--json']);
      expect(live.json as List<dynamic>, isEmpty);

      final trash = await lck(['note', 'list', '--trash', '--json']);
      expect((trash.json as List<dynamic>).length, 1);
      // 文件仍在磁盘上，只是标记为已删除。
      expect(noteFile(id).existsSync(), isTrue);
    });

    test('26. note restore 从回收站恢复', () async {
      final id = await createNote('# 草稿\n正文\n');
      await lck(['note', 'rm', id]);
      final result = await lck(['note', 'restore', id]);
      expect(result.exitCode, 0);

      final live = await lck(['note', 'list', '--json']);
      expect((live.json as List<dynamic>).length, 1);
    });

    test('27. note purge 缺 --yes 退出码 2 且笔记仍在', () async {
      final id = await createNote('# 草稿\n正文\n');
      await lck(['note', 'rm', id]);

      final result = await lck(['note', 'purge', id]);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('--yes'));
      expect(noteFile(id).existsSync(), isTrue);
    });

    test('28. note purge --yes 永久删除', () async {
      final id = await createNote('# 草稿\n正文\n');
      await lck(['note', 'rm', id]);

      final result = await lck(['note', 'purge', id, '--yes']);
      expect(result.exitCode, 0);
      expect(noteFile(id).existsSync(), isFalse, reason: '文件应已从磁盘删除');

      final trash = await lck(['note', 'list', '--trash', '--json']);
      expect(trash.json as List<dynamic>, isEmpty);
    });

    test('29. folder rm 删除文件夹并把内含笔记移入回收站', () async {
      await lck(['folder', 'new', '临时']);
      final id = await createNote('# 笔记\n正文\n');
      await lck(['note', 'mv', id, '--folder', '临时']);

      final result = await lck(['folder', 'rm', '临时']);
      expect(result.exitCode, 0);

      final folders = await lck(['folder', 'list', '--json']);
      expect(folders.json as List<dynamic>, isEmpty);

      // 笔记进回收站，但不永久删除。
      final live = await lck(['note', 'list', '--json']);
      expect(live.json as List<dynamic>, isEmpty);
      final trash = await lck(['note', 'list', '--trash', '--json']);
      expect((trash.json as List<dynamic>).length, 1);
      expect(noteFile(id).existsSync(), isTrue);
    });

    test('30. 关键词命中多篇时退出码 2 并列出候选', () async {
      await createNote('# 调研纪要 A\n正文\n');
      await createNote('# 调研纪要 B\n正文\n');

      final result = await lck(['note', 'show', '调研纪要']);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('匹配到多篇'));
      expect(result.stderr, contains('调研纪要 A'));
      expect(result.stderr, contains('调研纪要 B'));
    });

    test('31. 关键词命中零篇时退出码 2', () async {
      await createNote('# 笔记\n正文\n');
      final result = await lck(['note', 'show', '不存在的关键词']);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('找不到笔记'));
    });

    test('31b. 完整 ID 可以唯一定位', () async {
      final id = await createNote('# 调研纪要 A\n正文\n');
      await createNote('# 调研纪要 B\n正文\n');

      final result = await lck(['note', 'show', id, '--json']);
      expect(result.exitCode, 0);
      final data = result.json as Map<String, dynamic>;
      expect(data['id'], id);
      expect(data['content'], '# 调研纪要 A\n正文\n');
    });
  });

  // -------------------------------------------------------------------------
  group('输出契约', () {
    test('32. --json 空为 []、多条为数组、单条为对象', () async {
      // 空结果 → []
      final empty = await lck(['note', 'list', '--json']);
      expect(empty.stdout.trim(), '[]');

      // 多条 → 数组
      await createNote('# 甲\n正文\n');
      await createNote('# 乙\n正文\n');
      final many = await lck(['note', 'list', '--json']);
      expect(many.json, isA<List<dynamic>>());
      expect((many.json as List<dynamic>).length, 2);

      // 列表类命令即使只命中一条也是数组（不是单对象）
      final oneHit = await lck(['note', 'search', '甲', '--json']);
      expect(oneHit.json, isA<List<dynamic>>());
      expect((oneHit.json as List<dynamic>).length, 1);

      // 单条命令 → 对象
      final single = await lck(['status', '--json']);
      expect(single.json, isA<Map<String, dynamic>>());
    });

    test('33. 失败时 stdout 无结构化数据，错误只在 stderr', () async {
      final result = await lck(['note', 'show', '不存在', '--json']);
      expect(result.exitCode, 2);
      expect(result.stdout, isEmpty);
      expect(result.stderr, isNotEmpty);
      // 错误输出不是 JSON。
      expect(() => jsonDecode(result.stderr), throwsFormatException);
    });

    test('45. 数据损坏时退出码 1，错误在 stderr', () async {
      // 写一个非法 notebook.json，LocalStore.init 应当响亮失败而不是静默重建。
      File([sandbox.path, 'notebook.json'].join(Platform.pathSeparator))
          .writeAsStringSync('{ 这不是合法 JSON');

      final result = await lck(['status']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('错误：'));
      expect(result.stdout, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('参数严格化', () {
    test('41. 未声明的选项一律退出码 2', () async {
      final id = await createNote('# 笔记\n正文\n');
      final cases = <List<String>>[
        ['note', 'rm', id, '--title', 'T'],
        ['note', 'rm', id, '--folder', 'X'],
        ['note', 'show', id, '--body', 'X'],
        ['note', 'restore', id, '--title', 'T'],
        ['status', '--folder', 'X'],
        ['today', '--trash'],
        ['task', 'list', '--trash'],
        ['note', 'list', '--all'],
        ['task', 'add', 'X', '--yes'],
      ];
      for (final c in cases) {
        final result = await lck(c);
        expect(result.exitCode, 2, reason: '应拒绝：lck ${c.join(' ')}');
        expect(
          result.stderr,
          contains('不接受'),
          reason: '错误应说明参数不被接受：lck ${c.join(' ')}',
        );
      }
    });

    test('42. 命令组回退按默认子命令校验', () async {
      // lck note --trash 实际执行 note list，--trash 应被接受。
      final ok = await lck(['note', '--trash']);
      expect(ok.exitCode, 0);

      // lck note --all：note list 不接受 --all。
      final bad = await lck(['note', '--all']);
      expect(bad.exitCode, 2);
      expect(bad.stderr, contains('note list'));
    });

    test('43. 已声明的选项与全局项仍被接受', () async {
      for (final c in <List<String>>[
        ['note', 'list', '--trash'],
        ['task', 'list', '--all'],
        ['status', '--json'],
      ]) {
        final result = await lck(c);
        expect(result.exitCode, 0, reason: '应接受：lck ${c.join(' ')}');
      }
    });
  });
}
