import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/feed.dart';
import 'package:little_check/storage.dart';

void main() {
  test('platform labels come from fields, absent values use other', () {
    final item = <String, dynamic>{
      'id': 'a',
      'title': '标题',
      'summary': '',
      'content': '',
      'source': '来源',
      'published_at': '2026-10-03T00:00:00Z',
    };
    expect(
      FeedItem.fromJson({...item, 'url': 'https://github.com/a/b'})
          .platformName,
      '其他',
    );
    expect(
      FeedItem.fromJson({...item, 'platform': 'pixiv'}).platformName,
      'P站',
    );
    expect(FeedItem.fromJson({...item, 'platform': '新平台'}).platformName, '新平台');
  });
  late Directory directory;
  late LocalStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('little-check-test-');
    store = LocalStore(directory);
    await store.init();
  });
  tearDown(() async => directory.delete(recursive: true));

  test('note edits and settings survive a fresh store instance', () async {
    await store.saveNote('safe-id', '# 你好\n\n- [ ] 一件事');
    await store.saveNote('safe-id', '# 你好\n\n- [x] 一件事');
    await store.setSettings(
      endpoint: 'https://example.org/feed.json',
      theme: 'dark',
      palette: 'violet',
      font: 'wenkai',
    );
    final reopened = LocalStore(directory);
    await reopened.init();
    expect((await reopened.loadNotes()).single.content, '# 你好\n\n- [x] 一件事');
    expect(reopened.endpoint, 'https://example.org/feed.json');
    expect(reopened.theme, 'dark');
    expect(reopened.palette, 'violet');
    expect(reopened.font, 'system');
    expect(() => reopened.noteFile('../escape'), throwsFormatException);
  });

  test(
    'feed keeps last good cache after malformed response; 304 reuses it',
    () async {
      final feed = jsonDecode(
        await File('server/example-feed.json').readAsString(),
      ) as Map<String, dynamic>;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var mode = 200;
      server.listen((request) async {
        request.response.statusCode = mode;
        if (mode == 200) {
          request.response.headers.set('etag', '"one"');
          request.response.write(jsonEncode(feed));
        } else if (mode == 201) {
          request.response.statusCode = 200;
          request.response.write('{"items":"broken"}');
        } else if (mode == 304) {
          expect(request.headers.value('if-none-match'), '"one"');
        }
        await request.response.close();
      });
      final endpoint = 'http://127.0.0.1:${server.port}/feed.json';
      final client = FeedClient(store);
      expect((await client.refresh(endpoint)).items, hasLength(2));
      mode = 201;
      await expectLater(
        client.refresh(endpoint),
        throwsA(isA<FormatException>()),
      );
      expect((await store.readCache(endpoint))!['snapshot'], feed);
      expect(await store.readCache('$endpoint?other'), isNull);
      mode = 304;
      expect(
        (await client.refresh(endpoint)).items.first.id,
        'sample-flutter-20261002',
      );
    },
  );

  test('invalid settings are surfaced and never overwritten', () async {
    final file = File('${directory.path}/settings.json');
    await file.writeAsString('{bad');
    await expectLater(LocalStore(directory).init(), throwsFormatException);
    expect(await file.readAsString(), '{bad');
  });
}
