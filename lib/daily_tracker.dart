import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'storage.dart';
import 'image_cache.dart';

/// 一个壁纸来源。内置的必应源 [builtin] 为 true，始终置顶且不可删除。
class WallpaperSource {
  const WallpaperSource({
    required this.id,
    required this.name,
    required this.url,
    this.builtin = false,
  });

  final String id;
  final String name;
  final String url;
  final bool builtin;

  static const bing = WallpaperSource(
    id: 'bing',
    name: '必应每日风景',
    url: '',
    builtin: true,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'builtin': builtin,
  };

  static WallpaperSource fromJson(Map<String, dynamic> json) => WallpaperSource(
    id: json['id'] as String,
    name: json['name'] as String? ?? '壁纸源',
    url: json['url'] as String? ?? '',
    builtin: json['builtin'] == true,
  );
}

/// 壁纸取用方式。
enum WallpaperMode {
  /// 固定使用某个指定源。
  single,

  /// 每次刷新在启用的自定义源之间随机换图。
  rotate;

  static WallpaperMode parse(String? value) =>
      value == 'rotate' ? WallpaperMode.rotate : WallpaperMode.single;
}

class DailyTracker extends ChangeNotifier {
  DailyTracker(this.store);
  final LocalStore store;

  String _date = _todayString();
  int _opens = 0;
  int _feedReads = 0;
  final Map<String, int> _feedSources = {};
  int _aiTranslates = 0;
  int _aiSummaries = 0;
  int _wordsAdded = 0;
  int _wordsDeleted = 0;
  int _tasksCompleted = 0;
  bool _hasSavedToday = false;
  String? _wallpaperUrl;
  String? _wallpaperTitle;
  List<WallpaperSource> _wallpaperSources = [WallpaperSource.bing];
  WallpaperMode _wallpaperMode = WallpaperMode.single;
  String _activeWallpaperSourceId = WallpaperSource.bing.id;
  String? _lastWallpaperError;
  String? _lastSaveError;

  String get date => _date;
  int get opens => _opens;
  int get feedReads => _feedReads;
  Map<String, int> get feedSources => Map.unmodifiable(_feedSources);
  int get aiTranslates => _aiTranslates;
  int get aiSummaries => _aiSummaries;
  int get wordsAdded => _wordsAdded;
  int get wordsDeleted => _wordsDeleted;
  int get tasksCompleted => _tasksCompleted;
  bool get hasSavedToday => _hasSavedToday;
  String? get wallpaperUrl => _wallpaperUrl;
  String? get wallpaperTitle => _wallpaperTitle;

  /// 全部壁纸源，内置必应固定置顶。
  List<WallpaperSource> get wallpaperSources =>
      List.unmodifiable(_wallpaperSources);
  WallpaperMode get wallpaperMode => _wallpaperMode;
  String get activeWallpaperSourceId => _activeWallpaperSourceId;

  /// 最近一次自定义源抓取的失败原因；成功或使用必应时为 null。
  String? get lastWallpaperError => _lastWallpaperError;

  /// 最近一次统计落盘失败的原因；成功时为 null。
  String? get lastSaveError => _lastSaveError;

  /// 仅自定义源（可参与轮换、可编辑删除）。
  List<WallpaperSource> get customWallpaperSources =>
      _wallpaperSources.where((s) => !s.builtin).toList();

  static String _todayString() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// 提示红点逻辑：到了傍晚（19 点以后）且今日有活跃记录且尚未生成回顾笔记。
  bool get shouldShowBadge {
    if (_hasSavedToday) return false;
    final hour = DateTime.now().hour;
    final hasActivity =
        _opens > 0 ||
        _feedReads > 0 ||
        _wordsAdded > 0 ||
        _wordsDeleted > 0 ||
        _tasksCompleted > 0 ||
        (_aiTranslates + _aiSummaries) > 0;
    return hour >= 19 && hasActivity;
  }

  String get topFeedSource {
    if (_feedSources.isEmpty) return '常规资讯';
    var topSource = '常规资讯';
    var maxCount = 0;
    for (final entry in _feedSources.entries) {
      if (entry.value > maxCount) {
        maxCount = entry.value;
        topSource = entry.key;
      }
    }
    return topSource;
  }

  String get greeting {
    final hour = DateTime.now().hour;
    if (hour >= 5 && hour < 11) return '早安，新的一天开始探索';
    if (hour >= 11 && hour < 14) return '午安，稍作休息与回顾';
    if (hour >= 14 && hour < 18) return '下午好，继续专注与记录';
    if (hour >= 18 && hour < 23) return '晚上好，今天已记录你的足迹';
    return '夜深了，感谢今日的专注与思考';
  }

  Future<void> init() async {
    final raw = store.settings['dailyTracker'];
    if (raw is Map) {
      _loadWallpaperConfig(raw);
      final savedDate = raw['date'] as String? ?? '';
      if (savedDate == _todayString()) {
        _date = savedDate;
        _opens = (raw['opens'] as num?)?.toInt() ?? 0;
        _feedReads = (raw['feedReads'] as num?)?.toInt() ?? 0;
        if (raw['feedSources'] is Map) {
          for (final e in (raw['feedSources'] as Map).entries) {
            _feedSources[e.key.toString()] = (e.value as num?)?.toInt() ?? 0;
          }
        }
        _aiTranslates = (raw['aiTranslates'] as num?)?.toInt() ?? 0;
        _aiSummaries = (raw['aiSummaries'] as num?)?.toInt() ?? 0;
        _wordsAdded = (raw['wordsAdded'] as num?)?.toInt() ?? 0;
        _wordsDeleted = (raw['wordsDeleted'] as num?)?.toInt() ?? 0;
        _tasksCompleted = (raw['tasksCompleted'] as num?)?.toInt() ?? 0;
        _hasSavedToday = raw['hasSavedToday'] == true;
        _wallpaperUrl = raw['wallpaperUrl'] as String?;
        _wallpaperTitle = raw['wallpaperTitle'] as String?;
        if (_wallpaperUrl != null) {
          _prefetch(_wallpaperUrl!);
        }
      } else {
        // 新的一天，重置计数（壁纸配置跨天保留）
        _date = _todayString();
        _opens = 0;
        _feedReads = 0;
        _feedSources.clear();
        _aiTranslates = 0;
        _aiSummaries = 0;
        _wordsAdded = 0;
        _wordsDeleted = 0;
        _tasksCompleted = 0;
        _hasSavedToday = false;
        _wallpaperUrl = null;
        _wallpaperTitle = null;
      }
    }
    notifyListeners();
  }

  /// 懒加载：首次打开手帐弹层或进入壁纸源设置时调用，避免启动即联网下载。
  /// 若已有今日壁纸地址则直接复用，不重复请求。
  Future<void> ensureWallpaper() async {
    if (_wallpaperUrl != null && _wallpaperTitle != null) {
      _prefetch(_wallpaperUrl!);
      return;
    }
    await fetchWallpaper();
  }

  /// 后台预取壁纸到磁盘缓存，失败静默（离线或插件缺失时不影响主流程）。
  static void _prefetch(String url) {
    unawaited(
      imageFileCache.downloadFile(url).then<void>((_) {}, onError: (_) {}),
    );
  }

  void _loadWallpaperConfig(Map raw) {
    final sourcesRaw = raw['wallpaperSources'];
    if (sourcesRaw is List && sourcesRaw.isNotEmpty) {
      _wallpaperSources = [
        WallpaperSource.bing,
        for (final entry in sourcesRaw)
          if (entry is Map && entry['id'] != WallpaperSource.bing.id)
            WallpaperSource.fromJson(Map<String, dynamic>.from(entry)),
      ];
    } else {
      // 旧版本迁移：把单值 customWallpaperApi 提升为一个源
      final legacy = raw['customWallpaperApi'] as String?;
      _wallpaperSources = [
        WallpaperSource.bing,
        if (legacy != null && legacy.trim().isNotEmpty)
          WallpaperSource(id: 'legacy', name: '自定义壁纸', url: legacy.trim()),
      ];
    }
    _wallpaperMode = WallpaperMode.parse(raw['wallpaperMode'] as String?);
    final activeId = raw['activeWallpaperSourceId'] as String?;
    _activeWallpaperSourceId =
        activeId != null && _wallpaperSources.any((s) => s.id == activeId)
        ? activeId
        : (_wallpaperSources
              .firstWhere((s) => !s.builtin, orElse: () => WallpaperSource.bing)
              .id);
  }

  Future<void> _save() async {
    final data = {
      'date': _date,
      'opens': _opens,
      'feedReads': _feedReads,
      'feedSources': _feedSources,
      'aiTranslates': _aiTranslates,
      'aiSummaries': _aiSummaries,
      'wordsAdded': _wordsAdded,
      'wordsDeleted': _wordsDeleted,
      'tasksCompleted': _tasksCompleted,
      'hasSavedToday': _hasSavedToday,
      'wallpaperUrl': _wallpaperUrl,
      'wallpaperTitle': _wallpaperTitle,
      'wallpaperSources': [for (final s in _wallpaperSources) s.toJson()],
      'wallpaperMode': _wallpaperMode.name,
      'activeWallpaperSourceId': _activeWallpaperSourceId,
    };
    try {
      await store.setSettings(extra: {'dailyTracker': data});
      _lastSaveError = null;
    } catch (e) {
      // 落盘失败（磁盘满/权限等）：保留内存态并在界面提示，不再静默。
      _lastSaveError = '每日记录未能保存到本机：$e';
    }
    notifyListeners();
  }

  void recordOpen() {
    _checkDate();
    _opens++;
    unawaited(_save());
  }

  void recordFeedRead(String source) {
    _checkDate();
    _feedReads++;
    _feedSources[source] = (_feedSources[source] ?? 0) + 1;
    unawaited(_save());
  }

  void recordAiAction({required bool isSummary}) {
    _checkDate();
    if (isSummary) {
      _aiSummaries++;
    } else {
      _aiTranslates++;
    }
    unawaited(_save());
  }

  void recordNoteEdit({int added = 0, int deleted = 0, int tasks = 0}) {
    _checkDate();
    if (added > 0) _wordsAdded += added;
    if (deleted > 0) _wordsDeleted += deleted;
    if (tasks > 0) _tasksCompleted += tasks;
    unawaited(_save());
  }

  void _checkDate() {
    final today = _todayString();
    if (_date != today) {
      _date = today;
      _opens = 0;
      _feedReads = 0;
      _feedSources.clear();
      _aiTranslates = 0;
      _aiSummaries = 0;
      _wordsAdded = 0;
      _wordsDeleted = 0;
      _tasksCompleted = 0;
      _hasSavedToday = false;
      _wallpaperUrl = null;
      _wallpaperTitle = null;
      // 跨天后补抓新壁纸，避免手帐顶部留白。
      unawaited(fetchWallpaper(force: true));
    }
  }

  /// 新增一个自定义壁纸源。
  Future<void> addWallpaperSource(String name, String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) throw const FormatException('API 地址不能为空');
    if (_wallpaperSources.any((s) => s.url == trimmed)) {
      throw const FormatException('已添加这个 API 地址');
    }
    final source = WallpaperSource(
      id: 'ws_${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? '自定义壁纸' : name.trim(),
      url: trimmed,
    );
    _wallpaperSources = [..._wallpaperSources, source];
    if (_activeWallpaperSourceId == WallpaperSource.bing.id) {
      _activeWallpaperSourceId = source.id;
    }
    _wallpaperUrl = null;
    _wallpaperTitle = null;
    await _save();
    await fetchWallpaper(force: true);
  }

  Future<void> updateWallpaperSource(String id, String name, String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) throw const FormatException('API 地址不能为空');
    if (_wallpaperSources.any((s) => s.id != id && s.url == trimmed)) {
      throw const FormatException('已添加这个 API 地址');
    }
    _wallpaperSources = [
      for (final s in _wallpaperSources)
        s.id == id && !s.builtin
            ? WallpaperSource(
                id: s.id,
                name: name.trim().isEmpty ? s.name : name.trim(),
                url: trimmed,
              )
            : s,
    ];
    _wallpaperUrl = null;
    _wallpaperTitle = null;
    await _save();
    if (_activeWallpaperSourceId == id) await fetchWallpaper(force: true);
  }

  Future<void> removeWallpaperSource(String id) async {
    if (id == WallpaperSource.bing.id) return;
    _wallpaperSources = _wallpaperSources.where((s) => s.id != id).toList();
    if (_activeWallpaperSourceId == id) {
      _activeWallpaperSourceId =
          customWallpaperSources.firstOrNull?.id ?? WallpaperSource.bing.id;
    }
    _wallpaperUrl = null;
    _wallpaperTitle = null;
    await _save();
    await fetchWallpaper(force: true);
  }

  Future<void> setWallpaperMode(WallpaperMode mode) async {
    _wallpaperMode = mode;
    _wallpaperUrl = null;
    _wallpaperTitle = null;
    await _save();
    await fetchWallpaper(force: true);
  }

  Future<void> setActiveWallpaperSource(String id) async {
    if (!_wallpaperSources.any((s) => s.id == id)) return;
    _activeWallpaperSourceId = id;
    _wallpaperMode = WallpaperMode.single;
    _wallpaperUrl = null;
    _wallpaperTitle = null;
    await _save();
    await fetchWallpaper(force: true);
  }

  /// 手动刷新壁纸：清空当前地址后重新拉取（随机接口会换一张新图）。
  Future<void> refreshWallpaper() async {
    _wallpaperUrl = null;
    _wallpaperTitle = null;
    await fetchWallpaper(force: true);
    notifyListeners();
  }

  Future<void> fetchWallpaper({bool force = false}) async {
    if (!force && _wallpaperUrl != null && _wallpaperTitle != null) return;
    _lastWallpaperError = null;
    final source = _pickSource();
    if (source.builtin) {
      await _fetchBingWallpaper(rotate: force);
    } else {
      await _fetchCustomWallpaper(source);
    }
  }

  /// 决定本次取哪个源：轮换模式在自定义源中随机；无自定义源时回退必应。
  WallpaperSource _pickSource() {
    final customs = customWallpaperSources;
    if (_wallpaperMode == WallpaperMode.rotate && customs.isNotEmpty) {
      return customs[Random().nextInt(customs.length)];
    }
    return _wallpaperSources.firstWhere(
      (s) => s.id == _activeWallpaperSourceId,
      orElse: () => WallpaperSource.bing,
    );
  }

  Future<void> _fetchCustomWallpaper(WallpaperSource source) async {
    final apiUrl = source.url;
    HttpClient? client;
    try {
      final uri = Uri.parse(apiUrl);
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'LittleCheck/1.0');
      final response = await request.close();
      final contentType = response.headers.contentType?.mimeType ?? '';

      String imageUrl;
      var title = source.name;

      if (contentType.startsWith('image/')) {
        // 直链，或 302 重定向到图片（如 alcy / paulzzh / loliapi）：
        // 取重定向后的最终地址，保证每次刷新得到唯一 URL，缓存键随之变化。
        final resolved = _finalRedirectUrl(uri, response);
        // 若最终地址与接口地址相同（无重定向），或与上次完全相同
        // （服务端每次 302 到同一张图），追加一次性参数强制换图。
        imageUrl = (resolved == apiUrl || resolved == _wallpaperUrl)
            ? _bustCache(resolved)
            : resolved;
      } else {
        final text = await response.transform(utf8.decoder).join();
        Object? decoded;
        try {
          decoded = jsonDecode(text);
        } catch (_) {
          decoded = null;
        }
        String? extracted;
        if (decoded != null) {
          extracted = _findImageUrl(decoded);
          title = _findTitle(decoded) ?? source.name;
        } else {
          // 非 JSON 时按纯文本直链处理
          final trimmed = text.trim();
          if (trimmed.startsWith('http') && trimmed.length < 2048) {
            extracted = trimmed;
          }
        }
        if (extracted == null || extracted.isEmpty) {
          throw const FormatException('未从接口返回中解析到图片地址');
        }
        imageUrl = extracted.startsWith('http')
            ? extracted
            : uri.resolve(extracted).toString();
      }

      _lastWallpaperError = null;
      await _applyWallpaper(imageUrl, title, uri);
    } catch (e) {
      _lastWallpaperError = e is FormatException ? e.message : '该壁纸源暂时不可用';
      // 抓取失败时回退必应，但保留错误供界面提示
      await _fetchBingWallpaper();
    } finally {
      client?.close(force: true);
    }
  }

  /// 依次折叠重定向链，得到最终绝对地址（location 可能为相对路径）。
  static String _finalRedirectUrl(Uri original, HttpClientResponse response) {
    var resolved = original;
    for (final redirect in response.redirects) {
      resolved = resolved.resolveUri(redirect.location);
    }
    return resolved.toString();
  }

  /// 为固定直链追加一次性参数，避免命中同一份磁盘缓存。
  static String _bustCache(String url) {
    final uri = Uri.parse(url);
    return uri
        .replace(
          queryParameters: {
            ...uri.queryParameters,
            '_lc': DateTime.now().microsecondsSinceEpoch.toString(),
          },
        )
        .toString();
  }

  /// 移除 [_bustCache] 追加的一次性参数，还原为可长期引用的干净地址。
  static String _stripCacheBust(String url) {
    final uri = Uri.parse(url);
    if (!uri.queryParameters.containsKey('_lc')) return url;
    final params = Map<String, String>.from(uri.queryParameters)..remove('_lc');
    return uri
        .replace(queryParameters: params.isEmpty ? null : params)
        .toString();
  }

  Future<void> _applyWallpaper(String url, String title, Uri base) async {
    final fullUrl = url.startsWith('http') ? url : base.resolve(url).toString();
    _wallpaperUrl = fullUrl;
    _wallpaperTitle = title;
    await _save();
    _prefetch(fullUrl);
  }

  /// 递归遍历 JSON，找出第一个看起来像图片地址的字符串。
  /// 优先匹配 url 类字段，其次任意图片扩展名，兼容 lolicon 等嵌套结构。
  static String? _findImageUrl(Object? data) {
    const urlKeys = [
      'url',
      'imgurl',
      'image',
      'pic',
      'original',
      'src',
      'link',
    ];
    final preferred = <String>[];
    final fallback = <String>[];
    const maxDepth = 12;

    void visit(Object? node, int depth) {
      if (depth > maxDepth) return;
      if (node is Map) {
        for (final entry in node.entries) {
          final key = entry.key.toString().toLowerCase();
          final value = entry.value;
          if (value is String && _looksLikeImage(value)) {
            (urlKeys.contains(key) ? preferred : fallback).add(value);
          }
          visit(value, depth + 1);
        }
      } else if (node is List) {
        for (final item in node) {
          visit(item, depth + 1);
        }
      }
    }

    visit(data, 0);
    return preferred.firstOrNull ?? fallback.firstOrNull;
  }

  static bool _looksLikeImage(String value) {
    if (!value.startsWith('http')) return false;
    final path = Uri.tryParse(value)?.path.toLowerCase() ?? '';
    return path.endsWith('.jpg') ||
        path.endsWith('.jpeg') ||
        path.endsWith('.png') ||
        path.endsWith('.webp') ||
        path.endsWith('.gif') ||
        path.endsWith('.bmp');
  }

  static String? _findTitle(Object? data) {
    if (data is Map) {
      for (final key in [
        'title',
        'copyright',
        'name',
        'author',
        'description',
      ]) {
        final value = data[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
      for (final value in data.values) {
        final found = _findTitle(value);
        if (found != null) return found;
      }
    } else if (data is List) {
      for (final item in data) {
        final found = _findTitle(item);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// 抓取必应壁纸。[rotate] 为 true（手动刷新）时在最近若干天中随机挑一张，
  /// 否则固定取今天这张。
  Future<void> _fetchBingWallpaper({bool rotate = false}) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      // 取最近 8 天；idx=0 恒为今天同一张，多取几张供刷新轮换。
      final request = await client.getUrl(
        Uri.parse(
          'https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=zh-CN',
        ),
      );
      final response = await request.close();
      if (response.statusCode == 200) {
        final text = await response.transform(utf8.decoder).join();
        final json = jsonDecode(text);
        if (json is Map &&
            json['images'] is List &&
            (json['images'] as List).isNotEmpty) {
          final images = json['images'] as List;
          final picked =
              (rotate && images.length > 1
                      ? images[Random().nextInt(images.length)]
                      : images.first)
                  as Map;
          final path = picked['url'] as String? ?? '';
          final copyright = picked['copyright'] as String? ?? '必应每日精选风景';
          if (path.isNotEmpty) {
            _wallpaperUrl = path.startsWith('http')
                ? path
                : 'https://www.bing.com$path';
            _wallpaperTitle = copyright;
            await _save();
            _prefetch(_wallpaperUrl!);
          }
        }
      }
    } catch (_) {
      // 网络失败或离线时保持优雅降级
    } finally {
      client?.close(force: true);
    }
  }

  String generateMarkdown() {
    final buffer = StringBuffer();
    buffer.writeln('# $_date 每日回顾\n');
    buffer.writeln('> 🌙 $greeting。在 Little Check 记录你的数字足迹。\n');

    if (_wallpaperUrl != null && _wallpaperTitle != null) {
      // 去掉为击穿缓存追加的一次性参数，保证写入笔记的链接干净可用。
      final clean = _stripCacheBust(_wallpaperUrl!);
      buffer.writeln('![$_wallpaperTitle]($clean)');
      buffer.writeln('*今日背景：$_wallpaperTitle*\n');
    }

    buffer.writeln('### 📊 今日足迹');
    buffer.writeln('- 📱 **应用活跃**：共打开应用 $_opens 次；');
    if (_feedReads > 0) {
      buffer.writeln('- 📰 **信息流探索**：浏览了 $_feedReads 篇动态，最关注「$topFeedSource」；');
    } else {
      buffer.writeln('- 📰 **信息流探索**：今日暂无动态阅读；');
    }
    final totalAi = _aiTranslates + _aiSummaries;
    if (totalAi > 0) {
      buffer.writeln(
        '- ✨ **AI 辅助**：调用了 $totalAi 次智能操作（$_aiTranslates 篇翻译 · $_aiSummaries 篇总结）；',
      );
    }
    buffer.writeln(
      '- ✍️ **笔记创作**：今日新增记录了 $_wordsAdded 字，整理删减了 $_wordsDeleted 字；',
    );
    if (_tasksCompleted > 0) {
      buffer.writeln('- 🎯 **待办推进**：完成并勾选了 $_tasksCompleted 项任务；');
    }

    buffer.writeln('\n---\n');
    buffer.writeln('### 💭 随笔札记');
    buffer.writeln('（在此写下今天的总结与反思…）\n');

    return buffer.toString();
  }

  Future<Note> saveToFolder() async {
    _checkDate();
    const folderName = '每日回顾';
    var folderId = store.folders.entries
        .where((e) => e.value == folderName)
        .map((e) => e.key)
        .firstOrNull;

    if (folderId == null) {
      folderId = store.newNoteId();
      await store.putFolder(folderId, folderName);
    }

    final content = generateMarkdown();
    // 当天已生成过手帐则复用同一篇（标题以日期开头），避免重复新建。
    final existing = await _findTodayLog(folderId);
    final note = await store.saveNote(
      existing?.id ?? store.newNoteId(),
      content,
    );
    if (existing == null) {
      await store.moveNote(note.id, folderId);
    }

    _hasSavedToday = true;
    await _save();

    return Note(
      id: note.id,
      content: content,
      updatedAt: note.updatedAt,
      folderId: folderId,
    );
  }

  /// 在「每日回顾」文件夹中查找当天已生成的手帐（标题形如「# YYYY-MM-DD 每日回顾」）。
  Future<Note?> _findTodayLog(String folderId) async {
    final prefix = '# $_date ';
    final notes = await store.loadNotes();
    return notes
        .where(
          (n) =>
              n.folderId == folderId && n.content.trimLeft().startsWith(prefix),
        )
        .firstOrNull;
  }
}
