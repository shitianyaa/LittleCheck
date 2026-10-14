import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'sync_models.dart';

class Note {
  const Note({
    required this.id,
    required this.content,
    required this.updatedAt,
    this.folderId,
    this.deletedAt,
  });
  final String id;
  final String content;
  final DateTime updatedAt;
  final String? folderId;
  final DateTime? deletedAt;
  String get title {
    final first = content
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .firstOrNull;
    final title = first == null
        ? '未命名笔记'
        : first.replaceFirst(RegExp(r'^\s*#+\s*'), '').trim();
    return id.startsWith('conflict_') ? '$title（冲突副本）' : title;
  }

  String get excerpt => content.split('\n').skip(1).join(' ').trim();
}

class DataCopyResult {
  const DataCopyResult({required this.files, required this.bytes});

  final int files;
  final int bytes;
}

class LocalStore {
  LocalStore(this.directory);
  final Directory directory;
  Future<void> _writes = Future.value();
  final Set<String> _editingNotes = {};
  Map<String, dynamic> settings = {};
  Map<String, dynamic> _notebook = {
    'folders': <String, dynamic>{},
    'notes': <String, dynamic>{},
  };
  Map<String, dynamic> _syncState = {
    'schemaVersion': 1,
    'noteTombstones': <String, dynamic>{},
    'folderTombstones': <String, dynamic>{},
    'baselines': <String, dynamic>{},
  };
  Map<String, String> get folders =>
      Map<String, String>.from(_notebook['folders'] as Map);
  Set<String> get noteTombstones =>
      Set<String>.from((_syncState['noteTombstones'] as Map).keys);
  Set<String> get folderTombstones =>
      Set<String>.from((_syncState['folderTombstones'] as Map).keys);
  List<Map<String, dynamic>> get subscriptions {
    if (settings['subscriptions'] is List) {
      return (settings['subscriptions'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return endpoint.isEmpty
        ? []
        : [
            {'id': 'legacy', 'name': '我的订阅', 'url': endpoint, 'enabled': true},
          ];
  }

  String get endpoint => settings['endpoint'] as String? ?? '';
  int get feedRetentionDays => settings['feedRetentionDays'] as int? ?? 7;
  String get theme => settings['theme'] as String? ?? 'system';
  String get palette => settings['palette'] as String? ?? 'blue';
  String? fontError;
  String get font =>
      settings['font'] == 'custom' && fontError == null ? 'custom' : 'system';
  Directory get notesDirectory => Directory('${directory.path}/notes');

  String _normalizedDirectoryPath(Directory value) {
    var path = value.absolute.path.replaceAll(
      Platform.isWindows ? '/' : '\\',
      Platform.pathSeparator,
    );
    while (path.length > 1 && path.endsWith(Platform.pathSeparator)) {
      path = path.substring(0, path.length - 1);
    }
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  Future<String> _fileDigest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<DataCopyResult> copyDataTo(Directory target) => _enqueue(() async {
    if (hasOpenNotes) {
      throw const FormatException('请先保存并退出打开的笔记，再迁移数据目录');
    }
    await _recoverSyncJournal();
    final sourcePath = _normalizedDirectoryPath(directory);
    final targetPath = _normalizedDirectoryPath(target);
    final separator = Platform.pathSeparator;
    if (sourcePath == targetPath ||
        targetPath.startsWith('$sourcePath$separator') ||
        sourcePath.startsWith('$targetPath$separator')) {
      throw const FormatException('新数据目录不能与当前目录相同，也不能互相包含');
    }
    final existed = await target.exists();
    if (existed) {
      await for (final _ in target.list(followLinks: false)) {
        throw const FormatException('请选择一个空文件夹作为新的数据目录');
      }
    } else {
      await target.create(recursive: true);
    }

    var files = 0;
    var bytes = 0;
    try {
      final sourceRoot = directory.absolute.path;
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.link) {
          throw const FormatException('数据目录包含符号链接，未执行迁移');
        }
        final absolute = entity.absolute.path;
        final relative = absolute.substring(sourceRoot.length + 1);
        final destinationPath = '${target.absolute.path}$separator$relative';
        if (type == FileSystemEntityType.directory) {
          await Directory(destinationPath).create(recursive: true);
          continue;
        }
        if (type != FileSystemEntityType.file) continue;
        final source = File(absolute);
        final destination = File(destinationPath);
        await destination.parent.create(recursive: true);
        final length = await source.length();
        final digest = await _fileDigest(source);
        await source.copy(destination.path);
        if (await destination.length() != length ||
            await _fileDigest(destination) != digest) {
          throw const FormatException('迁移后的文件校验失败，原数据未改动');
        }
        files++;
        bytes += length;
      }
      final verification = LocalStore(target);
      await verification.init();
      return DataCopyResult(files: files, bytes: bytes);
    } catch (_) {
      try {
        if (await target.exists()) await target.delete(recursive: true);
        if (existed) await target.create(recursive: true);
      } catch (_) {
        // The source directory is still untouched; preserve the original error.
      }
      rethrow;
    }
  });

  Future<void> init() async {
    await notesDirectory.create(recursive: true);
    final file = File('${directory.path}/settings.json');
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          (decoded['endpoint'] != null && decoded['endpoint'] is! String) ||
          !['system', 'light', 'dark'].contains(decoded['theme'] ?? 'system') ||
          ![
            'blue',
            'green',
            'amber',
            'violet',
            'graphite',
          ].contains(decoded['palette'] ?? 'blue') ||
          ![
            'wenkai',
            'sans',
            'system',
            'custom',
          ].contains(decoded['font'] ?? 'system')) {
        throw const FormatException('设置文件损坏，原文件已保留');
      }
      settings = decoded;
      _validateSettings(settings);
    }
    final notebook = File('${directory.path}/notebook.json');
    if (await notebook.exists()) {
      final data = jsonDecode(await notebook.readAsString());
      if (data is! Map<String, dynamic>) {
        throw const FormatException('笔记目录损坏，原文件已保留');
      }
      _validateNotebook(data);
      _notebook = data;
    }
    await _loadSyncState();
    await _recoverSyncJournal();
  }

  File get _syncStateFile => File('${directory.path}/sync-state.json');
  File get _syncJournalFile => File('${directory.path}/sync-journal.json');

  void _validateNotebook(Map<String, dynamic> data) {
    if (data['folders'] is! Map || data['notes'] is! Map) {
      throw const FormatException('笔记目录损坏，原文件已保留');
    }
    for (final entry in (data['folders'] as Map).entries) {
      _validateEntityId(entry.key, '文件夹');
      if (entry.value is! String || (entry.value as String).trim().isEmpty) {
        throw const FormatException('笔记目录损坏，原文件已保留');
      }
    }
    for (final entry in (data['notes'] as Map).entries) {
      _validateEntityId(entry.key, '笔记');
      final meta = entry.value;
      if (meta is! Map ||
          (meta['folder'] != null && meta['folder'] is! String) ||
          (meta['deletedAt'] != null && meta['deletedAt'] is! String)) {
        throw const FormatException('笔记目录损坏，原文件已保留');
      }
      if (meta['folder'] != null) _validateEntityId(meta['folder'], '文件夹');
      if (meta['deletedAt'] != null) {
        DateTime.parse(meta['deletedAt'] as String);
      }
    }
  }

  void _validateEntityId(Object? value, String label) {
    if (value is! String || !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(value)) {
      throw FormatException('无效的$label ID');
    }
  }

  void _validateOperationId(Object? value) {
    if (value is! String ||
        !RegExp(r'^[a-zA-Z0-9_.:-]{1,160}$').hasMatch(value)) {
      throw const FormatException('无效的同步操作标识');
    }
  }

  Future<void> _loadSyncState() async {
    if (!await _syncStateFile.exists()) return;
    if (await _syncStateFile.length() > 2 * 1024 * 1024) {
      throw const FormatException('同步状态文件过大，原文件已保留');
    }
    final data = jsonDecode(await _syncStateFile.readAsString());
    if (data is! Map<String, dynamic>) {
      throw const FormatException('同步状态损坏，原文件已保留');
    }
    _validateSyncState(data);
    _syncState = data;
  }

  void _validateSyncState(Map<String, dynamic> data) {
    if (data['schemaVersion'] != 1 ||
        data['noteTombstones'] is! Map ||
        data['folderTombstones'] is! Map ||
        data['baselines'] is! Map) {
      throw const FormatException('同步状态损坏，原文件已保留');
    }
    for (final kind in ['noteTombstones', 'folderTombstones']) {
      for (final entry in (data[kind] as Map).entries) {
        _validateEntityId(entry.key, kind == 'noteTombstones' ? '笔记' : '文件夹');
        final meta = entry.value;
        if (meta is! Map ||
            meta['operationId'] is! String ||
            meta['deletedAt'] is! String) {
          throw const FormatException('同步删除标记损坏，原文件已保留');
        }
        _validateOperationId(meta['operationId']);
        DateTime.parse(meta['deletedAt'] as String);
      }
    }
    final hashPattern = RegExp(r'^[a-f0-9]{64}$');
    for (final entry in (data['baselines'] as Map).entries) {
      if (entry.key is! String ||
          (entry.key as String).isEmpty ||
          entry.value is! Map) {
        throw const FormatException('同步基线损坏，原文件已保留');
      }
      final baseline = entry.value as Map;
      if (baseline['notes'] is! Map || baseline['folders'] is! Map) {
        throw const FormatException('同步基线损坏，原文件已保留');
      }
      for (final group in ['notes', 'folders']) {
        for (final item in (baseline[group] as Map).entries) {
          _validateEntityId(item.key, group == 'notes' ? '笔记' : '文件夹');
          if (item.value is! String || !hashPattern.hasMatch(item.value)) {
            throw const FormatException('同步基线损坏，原文件已保留');
          }
        }
      }
    }
  }

  Future<void> _write(File file, String content) {
    final next = _writes.then((_) async {
      await _recoverSyncJournal();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(file.path);
    });
    // Continue subsequent saves after a failure; the caller receives the error.
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _writes.then((_) async {
      await _recoverSyncJournal();
      return action();
    });
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Map<String, dynamic> _copyMap(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

  Future<void> _writeAtomic(File file, String content) async {
    if (file.path == _syncStateFile.path &&
        utf8.encode(content).length > 2 * 1024 * 1024) {
      throw const FormatException('同步状态超过 2 MiB，未覆盖原文件');
    }
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(content, flush: true);
    await temporary.rename(file.path);
  }

  Future<void> _recoverSyncJournal() async {
    if (!await _syncJournalFile.exists()) return;
    if (await _syncJournalFile.length() > 40 * 1024 * 1024) {
      throw const FormatException('同步恢复记录过大，原文件已保留');
    }
    final decoded = jsonDecode(await _syncJournalFile.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('同步恢复记录损坏，原文件已保留');
    }
    await _applySyncJournal(decoded);
  }

  void _validateSyncJournal(Map<String, dynamic> journal) {
    if (journal['schemaVersion'] != 1 ||
        journal['operationId'] is! String ||
        journal['deleteNote'] is! bool ||
        journal['notebook'] is! Map ||
        journal['syncState'] is! Map) {
      throw const FormatException('同步恢复记录损坏，原文件已保留');
    }
    _validateOperationId(journal['operationId']);
    final noteId = journal['noteId'];
    if (noteId != null) _validateEntityId(noteId, '笔记');
    if (noteId == null && journal['deleteNote'] == true) {
      throw const FormatException('同步恢复记录损坏，原文件已保留');
    }
    if (noteId != null &&
        journal['deleteNote'] != true &&
        journal['noteContent'] is! String) {
      throw const FormatException('同步恢复记录损坏，原文件已保留');
    }
    if (journal['noteContent'] is String &&
        utf8.encode(journal['noteContent'] as String).length >
            2 * 1024 * 1024) {
      throw const FormatException('同步笔记超过 2 MiB，原恢复记录已保留');
    }
    final notebook = Map<String, dynamic>.from(journal['notebook'] as Map);
    final syncState = Map<String, dynamic>.from(journal['syncState'] as Map);
    _validateNotebook(notebook);
    _validateSyncState(syncState);
    if (utf8.encode(jsonEncode(syncState)).length > 2 * 1024 * 1024) {
      throw const FormatException('同步状态超过 2 MiB，未应用变化');
    }
    if (journal['noteChanges'] != null) {
      if (journal['noteChanges'] is! Map) {
        throw const FormatException('同步恢复记录格式无效');
      }
      for (final entry in (journal['noteChanges'] as Map).entries) {
        _validateEntityId(entry.key, '笔记');
        if (entry.value != null && entry.value is! String) {
          throw const FormatException('同步恢复正文格式无效');
        }
        if (entry.value is String &&
            utf8.encode(entry.value).length > 2 * 1024 * 1024) {
          throw const FormatException('同步笔记超过 2 MiB');
        }
      }
    }
  }

  Future<void> _applySyncJournal(Map<String, dynamic> journal) async {
    _validateSyncJournal(journal);
    for (final entry in (journal['noteChanges'] as Map? ?? {}).entries) {
      final file = noteFile(entry.key as String);
      if (entry.value == null) {
        if (await file.exists()) await file.delete();
      } else {
        await _writeAtomic(file, entry.value as String);
      }
    }
    final noteId = journal['noteId'] as String?;
    if (noteId != null) {
      final file = noteFile(noteId);
      if (journal['deleteNote'] == true) {
        if (await file.exists()) await file.delete();
      } else {
        await _writeAtomic(file, journal['noteContent'] as String);
      }
    }
    final notebook = Map<String, dynamic>.from(journal['notebook'] as Map);
    final syncState = Map<String, dynamic>.from(journal['syncState'] as Map);
    await _writeAtomic(
      File('${directory.path}/notebook.json'),
      jsonEncode(notebook),
    );
    await _writeAtomic(_syncStateFile, jsonEncode(syncState));
    _notebook = notebook;
    _syncState = syncState;
    if (await _syncJournalFile.exists()) await _syncJournalFile.delete();
  }

  Future<void> _commitSyncChange({
    required String operationId,
    required Map<String, dynamic> notebook,
    required Map<String, dynamic> syncState,
    String? noteId,
    String? noteContent,
    bool deleteNote = false,
  }) async {
    final journal = <String, dynamic>{
      'schemaVersion': 1,
      'operationId': operationId,
      'noteId': noteId,
      'noteContent': noteContent,
      'deleteNote': deleteNote,
      'notebook': notebook,
      'syncState': syncState,
    };
    _validateSyncJournal(journal);
    await _writeAtomic(_syncJournalFile, jsonEncode(journal));
    await _applySyncJournal(journal);
  }

  Future<void> setSettings({
    String? endpoint,
    String? theme,
    String? palette,
    String? font,
    Map<String, dynamic>? extra,
  }) {
    final operation = _writes.then((_) async {
      final next = {
        ...settings,
        ...?extra,
        'endpoint': ?endpoint,
        'theme': ?theme,
        'palette': ?palette,
        'font': ?font,
      };
      _validateSettings(next);
      final file = File('${directory.path}/settings.json');
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(next), flush: true);
      await temporary.rename(file.path);
      settings = next;
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  String newNoteId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}';

  void _validateSettings(Map<String, dynamic> data) {
    if ((data['actionParameters'] != null &&
            data['actionParameters'] is! Map) ||
        (data['actionModels'] != null && data['actionModels'] is! Map) ||
        (data['actionPrompts'] != null && data['actionPrompts'] is! Map) ||
        (data['actionReasoning'] != null &&
            ![
              '',
              'none',
              'minimal',
              'low',
              'medium',
              'high',
              'xhigh',
              'max',
            ].contains(data['actionReasoning']))) {
      throw const FormatException('AI 功能设置无效，原配置已保留');
    }
    for (final selection in (data['actionModels'] as Map? ?? {}).values) {
      if (selection != null &&
          (selection is! Map ||
              selection['providerId'] is! String ||
              selection['modelId'] is! String)) {
        throw const FormatException('AI 功能模型选择无效，原配置已保留');
      }
    }
    if ((data['actionPrompts'] as Map? ?? {}).values.any((v) => v is! String) ||
        (data['imageTranslationPrompt'] != null &&
            data['imageTranslationPrompt'] is! String)) {
      throw const FormatException('AI 提示词设置无效，原配置已保留');
    }
    if (data['feedRetentionDays'] != null &&
        (data['feedRetentionDays'] is! int ||
            data['feedRetentionDays'] < 1 ||
            data['feedRetentionDays'] > 90)) {
      throw const FormatException('信息流保留时间须为 1–90 天');
    }
    final custom = data['customFont'];
    if (custom != null &&
        (custom is! Map ||
            custom['name'] is! String ||
            custom['hash'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(custom['hash'] as String))) {
      throw const FormatException('自定义字体设置损坏，原文件已保留');
    }
    if (data['font'] == 'custom' && custom == null) {
      throw const FormatException('缺少自定义字体配置');
    }
    for (final key in ['subscriptions', 'aiProviders']) {
      final list = data[key];
      if (list == null) continue;
      if (list is! List) throw const FormatException('设置列表损坏，原文件已保留');
      final ids = <String>{};
      for (final entry in list) {
        if (entry is! Map ||
            entry['id'] is! String ||
            entry['name'] is! String ||
            (entry['name'] as String).trim().isEmpty ||
            !ids.add(entry['id'] as String)) {
          throw const FormatException('设置列表条目无效或重复');
        }
        if (key == 'subscriptions' &&
            (entry['url'] is! String || entry['enabled'] is! bool)) {
          throw const FormatException('订阅配置无效');
        }
        if (key == 'aiProviders' &&
            (entry['baseUrl'] is! String ||
                (entry['models'] == null &&
                    (entry['model'] is! String || entry['vision'] is! bool)))) {
          throw const FormatException('AI 供应商配置无效');
        }
        if (key == 'aiProviders' && entry['keys'] != null) {
          if (entry['keys'] is! List) throw const FormatException('密钥列表无效');
          final keyIds = <String>{};
          for (final item in entry['keys'] as List) {
            if (item is! Map ||
                item['id'] is! String ||
                item['name'] is! String ||
                item['enabled'] is! bool ||
                !keyIds.add(item['id'] as String) ||
                item.containsKey('value') ||
                item.containsKey('key')) {
              throw const FormatException('密钥元数据无效，密钥只能保存在安全存储');
            }
          }
        }
        if (key == 'aiProviders' && entry['models'] != null) {
          if (entry['models'] is! List ||
              ![
                'chat',
                'responses',
                'messages',
              ].contains(entry['protocol'] ?? 'chat')) {
            throw const FormatException('模型列表或协议无效');
          }
          final models = <String>{};
          for (final model in entry['models'] as List) {
            if (model is! Map ||
                model['id'] is! String ||
                (model['id'] as String).trim().isEmpty ||
                !models.add(model['id'] as String) ||
                model['alias'] is! String ||
                model['vision'] is! bool ||
                model['parameters'] is! Map ||
                model['inheritParameters'] is! bool ||
                ![
                  'chat',
                  'responses',
                  'messages',
                ].contains(model['protocol'] ?? entry['protocol'] ?? 'chat')) {
              throw const FormatException('模型配置无效或 ID 重复');
            }
          }
        }
      }
    }
  }

  File _translationFile(String key) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw const FormatException('无效的翻译缓存标识');
    }
    return File('${directory.path}/translations/$key.json');
  }

  Future<Map<String, dynamic>?> readTranslation(String key) async {
    final file = _translationFile(key);
    if (!await file.exists()) return null;
    if (await file.length() > 4 * 1024 * 1024) {
      throw const FormatException('翻译缓存超过 4 MiB，原文件已保留');
    }
    final data = jsonDecode(await file.readAsString());
    if (data is! Map<String, dynamic> ||
        data['text'] is! String ||
        data['model'] is! String ||
        data['notice'] is! String) {
      throw const FormatException('翻译缓存损坏，原文件已保留；可手动重新翻译');
    }
    return data;
  }

  Future<void> saveTranslation(String key, Map<String, dynamic> data) {
    final text = jsonEncode(data);
    if (utf8.encode(text).length > 4 * 1024 * 1024) {
      throw const FormatException('译文超过 4 MiB，未覆盖原缓存');
    }
    return _write(_translationFile(key), text);
  }

  File _actionImagesFile(String identity) => File(
    '${directory.path}/action-images/${sha256.convert(utf8.encode(identity))}.json',
  );

  Future<List<String>> readActionImages(String identity) async {
    final selection = await readActionSelection(identity);
    return (selection?['images'] as List? ?? []).cast<String>();
  }

  Future<Map<String, dynamic>?> readActionSelection(String identity) async {
    final file = _actionImagesFile(identity);
    if (!await file.exists()) return null;
    if (await file.length() > 32 * 1024) {
      throw const FormatException('图片选择缓存过大，原文件已保留');
    }
    final raw = jsonDecode(await file.readAsString());
    final value = raw is List ? {'images': raw} : raw;
    final images = value is Map ? value['images'] : null;
    if (value is! Map<String, dynamic> ||
        images is! List ||
        images.length > 3 ||
        images.any((v) => v is! String) ||
        (value['cacheId'] != null &&
            (value['cacheId'] is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['cacheId'])))) {
      throw const FormatException('图片选择缓存损坏，原文件已保留');
    }
    return value;
  }

  Future<void> saveActionImages(
    String identity,
    List<String> images, {
    String? cacheId,
  }) => _write(
    _actionImagesFile(identity),
    jsonEncode({'images': images, 'cacheId': cacheId}),
  );

  File _supplementFile(String repo) => File(
    '${directory.path}/readmes/${sha256.convert(utf8.encode(repo))}.json',
  );

  Future<Map<String, dynamic>?> readSupplement(String repo) async {
    final file = _supplementFile(repo);
    if (!await file.exists()) return null;
    if (await file.length() > 1024 * 1024) {
      throw const FormatException('README 缓存过大，原文件已保留');
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic> ||
        value['text'] is! String ||
        value['notice'] is! String ||
        value['url'] is! String) {
      throw const FormatException('README 缓存损坏，原文件已保留');
    }
    return value;
  }

  Future<void> saveSupplement(String repo, Map<String, dynamic> value) =>
      _write(_supplementFile(repo), jsonEncode(value));

  Future<Note> saveAiNote(String kind, String title, String content) async {
    const names = {'translate': 'AI 翻译', 'summary': 'AI 总结'};
    if (!names.containsKey(kind)) throw const FormatException('无效的 AI 动作');
    String? folderId;
    await _updateNotebook((data) {
      final folders = data['folders'] as Map;
      for (final entry in names.entries) {
        final existing = folders.entries
            .where((f) => f.value == entry.value)
            .firstOrNull;
        final preferred = 'ai_${entry.key}';
        final id =
            existing?.key as String? ??
            (folders.containsKey(preferred) ||
                    folderTombstones.contains(preferred)
                ? newNoteId()
                : preferred);
        folders.putIfAbsent(id, () => entry.value);
        if (entry.key == kind) folderId = id;
      }
    });
    final note = await saveNote(newNoteId(), '# $title\n\n$content');
    await moveNote(note.id, folderId);
    return Note(
      id: note.id,
      content: note.content,
      updatedAt: note.updatedAt,
      folderId: folderId,
    );
  }

  File _conversationFile(String identity) => File(
    '${directory.path}/conversations/${sha256.convert(utf8.encode(identity))}.json',
  );

  Future<Map<String, dynamic>?> readConversation(String identity) async {
    final file = _conversationFile(identity);
    if (!await file.exists()) return null;
    if (await file.length() > 4 * 1024 * 1024) {
      throw const FormatException('本地对话超过 4 MiB，原文件已保留');
    }
    final data = jsonDecode(await file.readAsString());
    if (data is! Map<String, dynamic> ||
        data['messages'] is! List ||
        data['draft'] is! String) {
      throw const FormatException('本地对话损坏，原文件已保留');
    }
    for (final message in data['messages'] as List) {
      if (message is! Map ||
          !['user', 'assistant'].contains(message['role']) ||
          (message['role'] == 'assistant'
              ? message['content'] is! String
              : message['display'] is! String) ||
          (message['content'] is! String && message['content'] is! List)) {
        throw const FormatException('本地对话格式损坏，原文件已保留');
      }
      for (final field in ['provider', 'model', 'error']) {
        if (message[field] != null && message[field] is! String) {
          throw const FormatException('本地对话格式损坏，原文件已保留');
        }
      }
      if (message['sources'] != null &&
          (message['sources'] is! List ||
              (message['sources'] as List).any(
                (source) =>
                    source is! Map ||
                    source['title'] is! String ||
                    source['url'] is! String,
              ))) {
        throw const FormatException('本地对话来源损坏，原文件已保留');
      }
      if (message['content'] is List) {
        for (final part in message['content'] as List) {
          if (part is! Map ||
              !(part['type'] == 'text' && part['text'] is String ||
                  part['type'] == 'image_url' &&
                      part['image_url'] is Map &&
                      part['image_url']['url'] is String)) {
            throw const FormatException('本地对话图片格式损坏，原文件已保留');
          }
        }
      }
    }
    return data;
  }

  Future<void> saveConversation(String identity, Map<String, dynamic> data) {
    final text = jsonEncode(data);
    if (utf8.encode(text).length > 4 * 1024 * 1024) {
      throw const FormatException('本地对话超过 4 MiB，未覆盖原文件；需要的回复仍可另存为笔记');
    }
    return _write(_conversationFile(identity), text);
  }

  void beginEditing(String id) {
    noteFile(id);
    _editingNotes.add(id);
  }

  void endEditing(String id) {
    _editingNotes.remove(id);
  }

  bool isEditing(String id) => _editingNotes.contains(id);

  bool get hasOpenNotes => _editingNotes.isNotEmpty;

  File get _syncTransferFile => File('${directory.path}/sync-transfer.json');

  Future<Map<String, dynamic>?> readSyncTransfer() => _enqueue(() async {
    if (!await _syncTransferFile.exists()) return null;
    if (await _syncTransferFile.length() > 40 * 1024 * 1024) {
      throw const FormatException('未完成同步记录过大，原文件已保留');
    }
    final data = jsonDecode(await _syncTransferFile.readAsString());
    if (data is! Map<String, dynamic> ||
        data['peerId'] is! String ||
        data['expectedFingerprint'] is! String ||
        data['manifest'] is! Map ||
        data['contents'] is! Map) {
      throw const FormatException('未完成同步记录损坏，原文件已保留');
    }
    return data;
  });

  Future<void> saveSyncTransfer(
    String peerId,
    String expectedFingerprint,
    SyncSnapshot target,
  ) => _enqueue(() async {
    target.validate();
    final encoded = jsonEncode({
      'peerId': peerId,
      'expectedFingerprint': expectedFingerprint,
      'manifest': target.manifest.toJson(),
      'contents': target.contents,
    });
    if (utf8.encode(encoded).length > 40 * 1024 * 1024) {
      throw const FormatException('未完成同步记录超过 40 MiB，未发送变化');
    }
    await _writeAtomic(_syncTransferFile, encoded);
  });

  Future<void> clearSyncTransfer() => _enqueue(() async {
    if (await _syncTransferFile.exists()) await _syncTransferFile.delete();
  });

  Future<void> forgetSyncPeer(String peerDeviceId) {
    _validateOperationId(peerDeviceId);
    return _enqueue(() async {
      final next = _copyMap(_syncState);
      (next['baselines'] as Map).remove(peerDeviceId);
      _validateSyncState(next);
      await _writeAtomic(_syncStateFile, jsonEncode(next));
      _syncState = next;
      if (await _syncTransferFile.exists()) {
        if (await _syncTransferFile.length() > 40 * 1024 * 1024) {
          await _syncTransferFile.delete();
          return;
        }
        try {
          final raw = jsonDecode(await _syncTransferFile.readAsString());
          if (raw is Map && raw['peerId'] == peerDeviceId) {
            await _syncTransferFile.delete();
          }
        } on FormatException {
          await _syncTransferFile.delete();
        }
      }
    });
  }

  Future<SyncSnapshot> syncSnapshot() => _enqueue(_syncSnapshot);

  Future<SyncSnapshot> _syncSnapshot() async {
    if (hasOpenNotes) throw const FormatException('请先保存并退出打开的笔记，再同步');
    final notes = <String, SyncNoteVersion>{};
    final contents = <String, String>{};
    var totalBytes = 0;
    await for (final entity in notesDirectory.list()) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final name = entity.uri.pathSegments.last;
      final id = name.substring(0, name.length - 3);
      noteFile(id);
      final size = await entity.length();
      if (size > 2 * 1024 * 1024) {
        throw FormatException('笔记 $id 超过 2 MiB，未读取或截断内容');
      }
      totalBytes += size;
      if (totalBytes > 32 * 1024 * 1024) {
        throw const FormatException('同步笔记总量超过 32 MiB，未读取或截断内容');
      }
      if (noteTombstones.contains(id)) {
        throw FormatException('笔记 $id 同时存在正文和永久删除标记');
      }
      final meta = (_notebook['notes'] as Map)[id] as Map? ?? {};
      final content = await entity.readAsString();
      final deletedAt = meta['deletedAt'] == null
          ? null
          : DateTime.parse(meta['deletedAt'] as String);
      contents[id] = content;
      notes[id] = SyncNoteVersion(
        id: id,
        contentHash: sha256.convert(utf8.encode(content)).toString(),
        folderId: meta['folder'] as String?,
        trashed: deletedAt != null,
      );
    }
    final folderVersions = <String, SyncFolderVersion>{};
    for (final entry in folders.entries) {
      if (folderTombstones.contains(entry.key)) {
        throw FormatException('文件夹 ${entry.key} 同时存在内容和永久删除标记');
      }
      folderVersions[entry.key] = SyncFolderVersion(
        id: entry.key,
        name: entry.value,
      );
    }
    final snapshot = SyncSnapshot(
      SyncManifest(
        notes: notes,
        folders: folderVersions,
        noteTombstones: noteTombstones,
        folderTombstones: folderTombstones,
      ),
      contents,
    );
    snapshot.validate();
    return snapshot;
  }

  Future<void> applySyncSnapshot(
    SyncSnapshot target, {
    required String expectedFingerprint,
  }) {
    target.validate();
    return _enqueue(() async {
      if (hasOpenNotes) throw const FormatException('请先保存并退出打开的笔记，再同步');
      final current = await _syncManifest();
      if (current.fingerprint != expectedFingerprint) {
        throw const FormatException('同步期间本地内容有变化，请重新同步');
      }
      final notebook = _copyMap(_notebook);
      notebook['folders'] = target.manifest.folders.map(
        (id, folder) => MapEntry(id, folder.name),
      );
      final previousMeta = notebook['notes'] as Map;
      notebook['notes'] = target.manifest.notes.map(
        (id, note) => MapEntry(id, {
          'folder': note.folderId,
          'deletedAt': note.trashed
              ? ((previousMeta[id] as Map?)?['deletedAt'] ??
                    DateTime.now().toUtc().toIso8601String())
              : null,
        }),
      );
      final state = _copyMap(_syncState);
      final operationId = 'batch_${target.manifest.fingerprint}';
      for (final kind in ['note', 'folder']) {
        final ids = kind == 'note'
            ? target.manifest.noteTombstones
            : target.manifest.folderTombstones;
        final old = state['${kind}Tombstones'] as Map;
        state['${kind}Tombstones'] = {
          for (final id in ids)
            id:
                old[id] ??
                {
                  'operationId': operationId,
                  'deletedAt': DateTime.now().toUtc().toIso8601String(),
                },
        };
      }
      // Every removed live item needs a tombstone; an incomplete target cannot erase data.
      if (current.notes.keys.any(
            (id) =>
                !target.manifest.notes.containsKey(id) &&
                !target.manifest.noteTombstones.contains(id),
          ) ||
          current.folders.keys.any(
            (id) =>
                !target.manifest.folders.containsKey(id) &&
                !target.manifest.folderTombstones.contains(id),
          ) ||
          !target.manifest.noteTombstones.containsAll(current.noteTombstones) ||
          !target.manifest.folderTombstones.containsAll(
            current.folderTombstones,
          )) {
        throw const FormatException('同步目标遗漏条目或删除标记');
      }
      final changes = <String, String?>{
        for (final id in target.manifest.notes.keys)
          if (current.notes[id]?.contentHash !=
              target.manifest.notes[id]!.contentHash)
            id: target.contents[id],
        for (final id in current.notes.keys)
          if (target.manifest.noteTombstones.contains(id)) id: null,
      };
      final journal = <String, dynamic>{
        'schemaVersion': 1,
        'operationId': operationId,
        'deleteNote': false,
        'notebook': notebook,
        'syncState': state,
        'noteChanges': changes,
      };
      _validateSyncJournal(journal);
      final encoded = jsonEncode(journal);
      if (utf8.encode(encoded).length > 40 * 1024 * 1024) {
        throw const FormatException('同步恢复记录超过 40 MiB');
      }
      await _writeAtomic(_syncJournalFile, encoded);
      await _applySyncJournal(journal);
    });
  }

  Future<SyncManifest> syncManifest() =>
      _enqueue(() async => (await _syncSnapshot()).manifest);

  Future<SyncManifest> _syncManifest() async =>
      (await _syncSnapshot()).manifest;

  Map<String, String> syncBaseline(
    String peerDeviceId, {
    required String kind,
  }) {
    _validateOperationId(peerDeviceId);
    if (!['notes', 'folders'].contains(kind)) {
      throw const FormatException('未知的同步基线类型');
    }
    final peer = (_syncState['baselines'] as Map)[peerDeviceId] as Map?;
    return Map<String, String>.from(peer?[kind] as Map? ?? const {});
  }

  Future<void> saveSyncBaseline(
    String peerDeviceId, {
    required Map<String, String> notes,
    required Map<String, String> folders,
  }) {
    _validateOperationId(peerDeviceId);
    final pattern = RegExp(r'^[a-f0-9]{64}$');
    for (final entry in [...notes.entries, ...folders.entries]) {
      _validateEntityId(entry.key, '同步条目');
      if (!pattern.hasMatch(entry.value)) {
        throw const FormatException('同步基线哈希无效');
      }
    }
    return _enqueue(() async {
      final next = _copyMap(_syncState);
      next['baselines'] = <String, dynamic>{
        peerDeviceId: {'notes': notes, 'folders': folders},
      };
      _validateSyncState(next);
      await _writeAtomic(_syncStateFile, jsonEncode(next));
      _syncState = next;
    });
  }

  Future<void> applySyncNoteMutation(SyncNoteMutation mutation) {
    _validateEntityId(mutation.id, '笔记');
    _validateOperationId(mutation.operationId);
    if (mutation.content != null &&
        utf8.encode(mutation.content!).length > 2 * 1024 * 1024) {
      throw const FormatException('同步笔记超过 2 MiB');
    }
    return _enqueue(() async {
      if (_editingNotes.contains(mutation.id)) {
        throw const FormatException('笔记正在打开，未应用远端修改');
      }
      final notebook = _copyMap(_notebook);
      final syncState = _copyMap(_syncState);
      final noteMeta = notebook['notes'] as Map;
      final tombstones = syncState['noteTombstones'] as Map;

      if (mutation.permanentDelete) {
        final existing = tombstones[mutation.id] as Map?;
        if (existing?['operationId'] == mutation.operationId &&
            !await noteFile(mutation.id).exists() &&
            !noteMeta.containsKey(mutation.id)) {
          return;
        }
        noteMeta.remove(mutation.id);
        tombstones[mutation.id] = {
          'operationId': mutation.operationId,
          'deletedAt': DateTime.now().toUtc().toIso8601String(),
        };
        await _commitSyncChange(
          operationId: mutation.operationId,
          notebook: notebook,
          syncState: syncState,
          noteId: mutation.id,
          deleteNote: true,
        );
        return;
      }

      if (tombstones.containsKey(mutation.id)) {
        throw const FormatException('该笔记已有永久删除标记，不能以原 ID 恢复');
      }
      if (mutation.folderId != null &&
          !(notebook['folders'] as Map).containsKey(mutation.folderId)) {
        throw const FormatException('同步笔记引用的文件夹不存在');
      }
      noteMeta[mutation.id] = {
        ...?noteMeta[mutation.id] as Map?,
        'folder': mutation.folderId,
        'deletedAt': mutation.trashed
            ? (mutation.deletedAt ?? DateTime.now().toUtc())
                  .toUtc()
                  .toIso8601String()
            : null,
      };
      await _commitSyncChange(
        operationId: mutation.operationId,
        notebook: notebook,
        syncState: syncState,
        noteId: mutation.id,
        noteContent: mutation.content!,
      );
    });
  }

  Future<void> applySyncFolderMutation(SyncFolderMutation mutation) {
    _validateEntityId(mutation.id, '文件夹');
    _validateOperationId(mutation.operationId);
    return _enqueue(() async {
      final notebook = _copyMap(_notebook);
      final syncState = _copyMap(_syncState);
      final folderMap = notebook['folders'] as Map;
      final tombstones = syncState['folderTombstones'] as Map;
      if (mutation.permanentDelete) {
        if ((notebook['notes'] as Map).values.any(
          (meta) => (meta as Map)['folder'] == mutation.id,
        )) {
          throw const FormatException('仍有笔记引用该文件夹，不能先应用文件夹删除');
        }
        final existing = tombstones[mutation.id] as Map?;
        if (existing?['operationId'] == mutation.operationId &&
            !folderMap.containsKey(mutation.id)) {
          return;
        }
        folderMap.remove(mutation.id);
        tombstones[mutation.id] = {
          'operationId': mutation.operationId,
          'deletedAt': DateTime.now().toUtc().toIso8601String(),
        };
      } else {
        final name = mutation.name!.trim();
        if (name.isEmpty || name.length > 80) {
          throw const FormatException('文件夹名称不能为空且最多 80 个字符');
        }
        if (tombstones.containsKey(mutation.id)) {
          throw const FormatException('该文件夹已有永久删除标记，不能以原 ID 恢复');
        }
        if (folderMap.entries.any(
          (entry) => entry.key != mutation.id && entry.value == name,
        )) {
          throw const FormatException('已有同名文件夹');
        }
        folderMap[mutation.id] = name;
      }
      await _commitSyncChange(
        operationId: mutation.operationId,
        notebook: notebook,
        syncState: syncState,
      );
    });
  }

  String _newSyncOperationId(String kind, String id) {
    final seed =
        '$kind:$id:${DateTime.now().microsecondsSinceEpoch}:'
        '${Random.secure().nextInt(1 << 32)}';
    return 'local_${kind}_'
        '${sha256.convert(utf8.encode(seed)).toString().substring(0, 40)}';
  }

  File noteFile(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id)) {
      throw const FormatException('无效的笔记文件名');
    }
    return File('${notesDirectory.path}/$id.md');
  }

  Future<Note> saveNote(String id, String content) async {
    final file = noteFile(id);
    await _enqueue(() async {
      if (noteTombstones.contains(id)) {
        throw const FormatException('笔记已永久删除，请另存为新笔记');
      }
      await _writeAtomic(file, content);
    });
    final meta = (_notebook['notes'] as Map)[id] as Map?;
    return Note(
      id: id,
      content: content,
      updatedAt: await file.lastModified(),
      folderId: meta?['folder'] as String?,
    );
  }

  Future<List<Note>> loadNotes({bool trash = false}) =>
      _enqueue(() => _loadNotes(trash: trash));

  /// 从磁盘重读 notebook.json 与 sync-state.json，同步外部（如 lck 命令行）
  /// 对文件夹结构、笔记归属与删除标记的改动。走 _enqueue 串行化，与写操作
  /// 共用队列避免竞态。
  Future<void> reloadNotebook() => _enqueue(() async {
    final file = File('${directory.path}/notebook.json');
    if (await file.exists()) {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map<String, dynamic>) {
        throw const FormatException('笔记目录损坏，原文件已保留');
      }
      _validateNotebook(data);
      _notebook = data;
    }
    await _loadSyncState();
  });

  Future<List<Note>> _loadNotes({bool trash = false}) async {
    final notes = <Note>[];
    await for (final entity in notesDirectory.list()) {
      if (entity is File && entity.path.endsWith('.md')) {
        final name = entity.uri.pathSegments.last;
        final id = name.substring(0, name.length - 3);
        noteFile(id);
        final meta = (_notebook['notes'] as Map)[id] as Map? ?? {};
        final deletedAt = meta['deletedAt'] == null
            ? null
            : DateTime.parse(meta['deletedAt'] as String);
        if (trash != (deletedAt != null)) continue;
        notes.add(
          Note(
            id: id,
            content: await entity.readAsString(),
            updatedAt: await entity.lastModified(),
            folderId: meta['folder'] as String?,
            deletedAt: deletedAt,
          ),
        );
      }
    }
    notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return notes;
  }

  Future<void> _updateNotebook(
    FutureOr<void> Function(Map<String, dynamic>) change,
  ) {
    final next = _writes.then((_) async {
      await _recoverSyncJournal();
      final data = jsonDecode(jsonEncode(_notebook)) as Map<String, dynamic>;
      await change(data);
      final file = File('${directory.path}/notebook.json');
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(data), flush: true);
      await temporary.rename(file.path);
      _notebook = data;
    });
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> putFolder(String id, String name) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id) ||
        name.trim().isEmpty ||
        name.trim().length > 80) {
      throw const FormatException('文件夹名称不能为空且最多 80 个字符');
    }
    return _updateNotebook((data) {
      if ((data['folders'] as Map).entries.any(
        (e) => e.key != id && e.value == name.trim(),
      )) {
        throw const FormatException('已有同名文件夹');
      }
      (data['folders'] as Map)[id] = name.trim();
      if (folderTombstones.contains(id)) {
        throw const FormatException('文件夹已删除，请使用新 ID');
      }
    });
  }

  Future<void> moveNote(String id, String? folderId) {
    noteFile(id);
    return _updateNotebook((data) {
      if (folderId != null && !(data['folders'] as Map).containsKey(folderId)) {
        throw const FormatException('文件夹不存在');
      }
      final notes = data['notes'] as Map;
      notes[id] = {...?notes[id] as Map?, 'folder': folderId};
    });
  }

  Future<void> trashNote(String id, {bool restore = false}) {
    noteFile(id);
    return _updateNotebook((data) async {
      final notes = data['notes'] as Map;
      if (!await noteFile(id).exists()) throw const FormatException('笔记已不存在');
      final meta = {
        ...?notes[id] as Map?,
        'deletedAt': restore ? null : DateTime.now().toUtc().toIso8601String(),
      };
      if (restore && !(data['folders'] as Map).containsKey(meta['folder'])) {
        meta['folder'] = null;
      }
      notes[id] = meta;
    });
  }

  Future<void> deleteFolder(String id, {required bool trashContents}) {
    _validateEntityId(id, '文件夹');
    return _enqueue(() async {
      final notebook = _copyMap(_notebook);
      final syncState = _copyMap(_syncState);
      final folderMap = notebook['folders'] as Map;
      if (!folderMap.containsKey(id)) {
        throw const FormatException('文件夹不存在');
      }
      folderMap.remove(id);
      for (final meta in (notebook['notes'] as Map).values) {
        if ((meta as Map)['folder'] != id) continue;
        meta['folder'] = null;
        if (trashContents && meta['deletedAt'] == null) {
          meta['deletedAt'] = DateTime.now().toUtc().toIso8601String();
        }
      }
      final operationId = _newSyncOperationId('folder-delete', id);
      (syncState['folderTombstones'] as Map)[id] = {
        'operationId': operationId,
        'deletedAt': DateTime.now().toUtc().toIso8601String(),
      };
      await _commitSyncChange(
        operationId: operationId,
        notebook: notebook,
        syncState: syncState,
      );
    });
  }

  Future<void> deleteNotePermanently(String id) {
    noteFile(id);
    return _enqueue(() async {
      if (_editingNotes.contains(id)) {
        throw const FormatException('笔记正在打开，不能彻底删除');
      }
      final notebook = _copyMap(_notebook);
      final syncState = _copyMap(_syncState);
      if (((notebook['notes'] as Map)[id] as Map?)?['deletedAt'] == null) {
        throw const FormatException('只能彻底删除回收站中的笔记');
      }
      (notebook['notes'] as Map).remove(id);
      final operationId = _newSyncOperationId('note-delete', id);
      (syncState['noteTombstones'] as Map)[id] = {
        'operationId': operationId,
        'deletedAt': DateTime.now().toUtc().toIso8601String(),
      };
      await _commitSyncChange(
        operationId: operationId,
        notebook: notebook,
        syncState: syncState,
        noteId: id,
        deleteNote: true,
      );
    });
  }

  Future<Map<String, dynamic>?> readCache(String endpoint) async {
    final file = _cacheFile(endpoint);
    if (!await file.exists()) return null;
    final cached = jsonDecode(await file.readAsString());
    if (cached is! Map<String, dynamic>) throw const FormatException('信息流缓存损坏');
    return cached['endpoint'] == endpoint ? cached : null;
  }

  Future<void> writeCache(
    String endpoint,
    Map<String, dynamic> snapshot,
    String? etag,
  ) => _write(
    _cacheFile(endpoint),
    jsonEncode({'endpoint': endpoint, 'snapshot': snapshot, 'etag': etag}),
  );

  File _cacheFile(String endpoint) => File(
    '${directory.path}/cache/${sha256.convert(utf8.encode(endpoint))}.json',
  );
}
