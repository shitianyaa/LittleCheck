import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/feed.dart';
import 'package:little_check/storage.dart';

import 'features_test.dart' show item;

class _Http extends HttpOverrides {}

void main() {
  final now = DateTime.utc(2026, 10, 3, 12);
  Map<String, dynamic> entry(String id, int age, {String? url, String? text}) =>
      {
        ...item(id, url: url),
        'published_at': now.subtract(Duration(days: age)).toIso8601String(),
        'content': text ?? '正文',
      };
  FeedSnapshot snapshot(List<Map<String, dynamic>> rows) =>
      FeedSnapshot.fromJson({
        'schema_version': 2,
        'generated_at': now.toIso8601String(),
        'items': rows,
      });

  test('refresh merges seven days, updates identity and expires older posts without a count cutoff', () {
    final old = snapshot([
      entry('kept', 6),
      entry('expired', 8),
      entry('old-id', 2, url: 'https://example.org/same'),
    ]);
    final recent = snapshot([
      entry('new-id', 0, url: 'https://example.org/same', text: '更新内容'),
      entry('new', 0),
    ]).retainHistory(old, now: now);
    expect(recent.items.map((i) => i.id).toSet(), {'kept', 'new-id', 'new'});
    expect(recent.items.firstWhere((i) => i.id == 'new-id').content, '更新内容');
    final many = snapshot([for (var i = 0; i < 500; i++) entry('old-$i', 1)]);
    final merged = snapshot([for (var i = 0; i < 500; i++) entry('new-$i', 0)])
        .retainHistory(many, now: now);
    expect(merged.items.length, 1000);
    expect(
      FeedSnapshot.fromJson(merged.json, history: true).items.length,
      1000,
    );
    expect(FeedSnapshot.merge({'source': merged}).items.length, 1000);
  });

  test('reused source IDs preserve different URLs across history reloads', () {
    final old = snapshot([entry('slot-1', 1, url: 'https://example.org/old')]);
    final next = snapshot([entry('slot-1', 0, url: 'https://example.org/new')])
        .retainHistory(old, now: now);
    expect(next.items.map((p) => p.url.toString()).toSet(), {
      'https://example.org/old',
      'https://example.org/new',
    });
    final reopened = FeedSnapshot.fromJson(next.json, history: true);
    final refreshed = snapshot([
      entry('slot-1', 0, url: 'https://example.org/new', text: '更新'),
    ]).retainHistory(reopened, now: now);
    expect(refreshed.items.length, 2);
    expect(
      refreshed.items
          .firstWhere((p) => p.url.toString().endsWith('/new'))
          .content,
      '更新',
    );
  });

  test(
    'ETag 304 prunes expired history and failures preserve the merged cache',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Http();
      addTearDown(() => HttpOverrides.global = previous);
      final directory = await Directory.systemTemp.createTemp(
        'little-check-history-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = LocalStore(directory);
      await store.init();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var mode = 200, round = 0, clock = now;
      server.listen((req) async {
        req.response.statusCode = mode;
        if (mode == 200) {
          req.response.headers.set('etag', '"history"');
          req.response.write(
            jsonEncode(
              snapshot(
                round++ == 0 ? [entry('first', 6)] : [entry('second', 0)],
              ).json,
            ),
          );
        }
        if (mode == 304) {
          expect(req.headers.value('if-none-match'), '"history"');
        }
        await req.response.close();
      });
      final endpoint = 'http://127.0.0.1:${server.port}/feed';
      final client = FeedClient(store, now: () => clock);
      expect((await client.refresh(endpoint)).items.length, 1);
      expect((await client.refresh(endpoint)).items.map((p) => p.id).toSet(), {
        'first',
        'second',
      });
      mode = 304;
      clock = now.add(const Duration(days: 2));
      expect((await client.refresh(endpoint)).items.map((p) => p.id).toList(), [
        'second',
      ]);
      final saved = await store.readCache(endpoint);
      mode = 500;
      await expectLater(
        client.refresh(endpoint),
        throwsA(isA<HttpException>()),
      );
      expect(await store.readCache(endpoint), equals(saved));
    },
  );
}
