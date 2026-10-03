import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'storage.dart';

DateTime feedDate(Object? value) {
  if (value is! String || !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
    throw const FormatException('发布时间必须包含时区');
  }
  return DateTime.parse(value);
}

Uri httpUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('请输入完整的 HTTP(S) 地址');
  }
  return uri;
}

class FeedItem {
  FeedItem.fromJson(Map<String, dynamic> json)
    : id = _text(json, 'id'),
      title = _text(json, 'title'),
      summary = _text(json, 'summary'),
      content = _text(json, 'content'),
      _platform = json['platform'],
      source = _text(json, 'source'),
      publishedAt = feedDate(json['published_at']),
      url = json['url'] == null ? null : httpUri(json['url'] as String),
      tags = json['tags'] == null
          ? []
          : List<String>.from(json['tags'] as List) {
    if (id.trim().isEmpty || title.trim().isEmpty) {
      throw const FormatException('信息条目缺少 ID 或标题');
    }
    if (json['platform'] != null && json['platform'] is! String) {
      throw const FormatException('platform 必须为文字');
    }
  }
  static String _text(Map<String, dynamic> json, String key) {
    if (json[key] is! String) throw FormatException('信息条目缺少 $key');
    return json[key] as String;
  }

  final String id, title, summary, content, source;
  final DateTime publishedAt;
  final Uri? url;
  final List<String> tags;
  String get platformName {
    final value = (_platform as String?)?.trim() ?? '';
    return switch (value) {
      '' || 'other' => '其他',
      'github' => 'GitHub',
      'pixiv' => 'P站',
      'twitter' => 'X·推特',
      _ => value,
    };
  }

  final Set<String> subscriptionIds = {};
  final Object? _platform;
}

class FeedSnapshot {
  FeedSnapshot.fromJson(this.json, {bool history = false})
    : generatedAt = feedDate(json['generated_at']) {
    if (![1, 2].contains(json['schema_version']) ||
        json['items'] is! List ||
        (!history && (json['items'] as List).length > 500)) {
      throw const FormatException('信息流格式不正确或超过 500 条');
    }
    items = (json['items'] as List)
        .map(
          (item) => FeedItem.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
    if (items.map((item) => item.id).toSet().length != items.length) {
      throw const FormatException('信息流中存在重复 ID');
    }
    items.sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
  }
  final Map<String, dynamic> json;
  final DateTime generatedAt;
  late List<FeedItem> items;

  FeedSnapshot retainHistory(
    FeedSnapshot? previous, {
    required DateTime now,
    int days = 7,
  }) {
    final cutoff = now.subtract(Duration(days: days));
    final entries = <String, Map<String, dynamic>>{};
    for (final raw in [
      ...?previous?.json['items'] as List?,
      ...json['items'] as List,
    ]) {
      final data = Map<String, dynamic>.from(raw as Map);
      if (feedDate(data['published_at']).isBefore(cutoff)) continue;
      final id = data['id'] as String, url = data['url'] as String?;
      final identity = url?.isNotEmpty == true ? 'url:$url' : 'id:$id';
      entries[identity] = data;
    }
    final counts = <String, int>{};
    for (final row in entries.values) {
      final id = row['id'] as String;
      counts[id] = (counts[id] ?? 0) + 1;
    }
    final ids = <String>{};
    for (final entry in entries.entries) {
      final row = entry.value;
      var id = row['id'] as String;
      if (counts[id]! > 1 || ids.contains(id)) {
        id = 'history:${sha256.convert(utf8.encode(entry.key))}';
        while (ids.contains(id)) {
          id = '$id:';
        }
        row['id'] = id;
      }
      ids.add(id);
    }
    return FeedSnapshot.fromJson({
      ...json,
      'items': entries.values.toList(),
    }, history: true);
  }

  static FeedSnapshot merge(Map<String, FeedSnapshot> snapshots) {
    final entries = <String, Map<String, dynamic>>{};
    final origins = <String, Set<String>>{};
    DateTime latest = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    for (final source in snapshots.entries) {
      if (source.value.generatedAt.isAfter(latest)) {
        latest = source.value.generatedAt;
      }
      for (final raw in source.value.json['items'] as List) {
        final data = Map<String, dynamic>.from(raw as Map);
        final uri = data['url'] as String?;
        final key = uri?.isNotEmpty == true
            ? uri!
            : '${source.key}:${data['id']}';
        origins.putIfAbsent(key, () => {}).add(source.key);
        final previous = entries[key];
        if (previous == null ||
            feedDate(data['published_at'])
                .isAfter(feedDate(previous['published_at']))) {
          entries[key] = data;
        }
      }
    }
    // Each source has its own 500-item limit; merged feeds are constructed separately.
    final result = FeedSnapshot.fromJson({
      'schema_version': 2,
      'generated_at': latest.toIso8601String(),
      'items': [],
    });
    result.items =
        entries.entries
            .map(
              (entry) =>
                  FeedItem.fromJson({...entry.value, 'id': entry.key})
                    ..subscriptionIds.addAll(origins[entry.key]!),
            )
            .toList()
          ..sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
    return result;
  }
}

class FeedClient {
  FeedClient(this.store, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  final LocalStore store;
  final DateTime Function() now;
  static const deadline = Duration(seconds: 20);

  Future<FeedSnapshot> refresh(String endpoint, {bool useCache = true}) async {
    final uri = httpUri(endpoint);
    final cached = useCache ? await store.readCache(endpoint) : null;
    final client = HttpClient()..connectionTimeout = deadline;
    try {
      final request = await client.getUrl(uri).timeout(deadline);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (cached?['etag'] is String) {
        request.headers.set(HttpHeaders.ifNoneMatchHeader, cached!['etag']);
      }
      final response = await request.close().timeout(deadline);
      if (response.statusCode == 304) {
        if (cached == null) throw const FormatException('服务返回 304，但没有可用缓存');
        final snapshot = FeedSnapshot.fromJson(
          Map<String, dynamic>.from(cached['snapshot'] as Map),
          history: true,
        ).retainHistory(null, now: now(), days: store.feedRetentionDays);
        if ((snapshot.json['items'] as List).length !=
            ((cached['snapshot'] as Map)['items'] as List).length) {
          await store.writeCache(
            endpoint,
            snapshot.json,
            cached['etag'] as String?,
          );
        }
        return snapshot;
      }
      if (response.statusCode != 200) {
        throw HttpException('服务返回 HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(deadline)) {
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          throw const FormatException('信息流超过 2 MiB，请在 VPS 减少条目或正文');
        }
        bytes.addAll(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      final snapshot =
          FeedSnapshot.fromJson(Map<String, dynamic>.from(decoded as Map))
              .retainHistory(
                cached == null
                    ? null
                    : FeedSnapshot.fromJson(
                        Map<String, dynamic>.from(cached['snapshot'] as Map),
                        history: true,
                      ),
                now: now(),
                days: store.feedRetentionDays,
              );
      await store.writeCache(
        endpoint,
        snapshot.json,
        response.headers.value(HttpHeaders.etagHeader),
      );
      return snapshot;
    } finally {
      client.close(force: true);
    }
  }
}
