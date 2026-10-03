import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

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
    return first == null
        ? '未命名笔记'
        : first.replaceFirst(RegExp(r'^\s*#+\s*'), '').trim();
  }

  String get excerpt => content.split('\n').skip(1).join(' ').trim();
}

class LocalStore {
  LocalStore(this.directory);
  final Directory directory;
  Future<void> _writes = Future.value();
  Map<String, dynamic> settings = {};
  Map<String, dynamic> _notebook = {
    'folders': <String, dynamic>{},
    'notes': <String, dynamic>{},
  };
  Map<String, String> get folders =>
      Map<String, String>.from(_notebook['folders'] as Map);
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
      if (data is! Map<String, dynamic> ||
          data['folders'] is! Map ||
          data['notes'] is! Map) {
        throw const FormatException('笔记目录损坏，原文件已保留');
      }
      _notebook = data;
      folders;
      for (final entry in (_notebook['notes'] as Map).entries) {
        noteFile(entry.key as String);
        final meta = entry.value;
        if (meta is! Map ||
            (meta['folder'] != null && meta['folder'] is! String) ||
            (meta['deletedAt'] != null && meta['deletedAt'] is! String)) {
          throw const FormatException('笔记目录损坏，原文件已保留');
        }
        if (meta['deletedAt'] != null) {
          DateTime.parse(meta['deletedAt'] as String);
        }
      }
    }
  }

  Future<void> _write(File file, String content) {
    final next = _writes.then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(file.path);
    });
    // Continue subsequent saves after a failure; the caller receives the error.
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
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
            (folders.containsKey(preferred) ? newNoteId() : preferred);
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

  File noteFile(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id)) {
      throw const FormatException('无效的笔记文件名');
    }
    return File('${notesDirectory.path}/$id.md');
  }

  Future<Note> saveNote(String id, String content) async {
    final file = noteFile(id);
    await _write(file, content);
    final meta = (_notebook['notes'] as Map)[id] as Map?;
    return Note(
      id: id,
      content: content,
      updatedAt: await file.lastModified(),
      folderId: meta?['folder'] as String?,
    );
  }

  Future<List<Note>> loadNotes({bool trash = false}) async {
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

  Future<void> deleteFolder(String id, {required bool trashContents}) =>
      _updateNotebook((data) {
        (data['folders'] as Map).remove(id);
        for (final meta in (data['notes'] as Map).values) {
          if ((meta as Map)['folder'] != id) continue;
          meta['folder'] = null;
          if (trashContents && meta['deletedAt'] == null) {
            meta['deletedAt'] = DateTime.now().toUtc().toIso8601String();
          }
        }
      });

  Future<void> deleteNotePermanently(String id) {
    final file = noteFile(id);
    return _updateNotebook((data) async {
      if (((data['notes'] as Map)[id] as Map?)?['deletedAt'] == null) {
        throw const FormatException('只能彻底删除回收站中的笔记');
      }
      if (await file.exists()) await file.delete();
      (data['notes'] as Map).remove(id);
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
