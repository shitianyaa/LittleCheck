import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/ai.dart';
import 'package:little_check/ai_page.dart';
import 'package:little_check/feed.dart';
import 'package:little_check/note_filename.dart';
import 'package:little_check/storage.dart';

Map<String, dynamic> item(String id, {String? platform, String? url}) => {
  'id': id,
  'title': '标题 $id',
  'summary': '',
  'content': '正文',
  'source': '账号',
  'published_at': '2026-10-03T08:00:00+08:00',
  'platform': ?platform,
  'url': ?url,
};
Map<String, dynamic> feed(List<Map<String, dynamic>> items) => {
  'schema_version': 2,
  'generated_at': '2026-10-03T08:00:00+08:00',
  'items': items,
};

class _SearchClient extends AiClient {
  Uri? sentUri;
  Map<String, dynamic>? sentBody;
  @override
  Future<Map<String, dynamic>> post(
    Uri uri,
    String key,
    Map<String, dynamic> body,
  ) async {
    sentUri = uri;
    sentBody = body;
    return {
      'results': [
        {
          'title': '资料',
          'url': 'https://example.org/article',
          'content': '结果正文',
        },
        {'title': '无效来源', 'url': 'javascript:alert(1)', 'content': '不应作为可点击来源'},
      ],
    };
  }
}

void main() {
  late Directory directory;
  late LocalStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('little-check-features-');
    store = LocalStore(directory);
    await store.init();
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'corrupt conversation metadata is rejected without overwriting history',
    () async {
      const data = {
        'draft': '',
        'messages': [
          {'role': 'assistant', 'content': '保留的回复', 'sources': '损坏'},
        ],
      };
      await store.saveConversation('post', data);
      await expectLater(store.readConversation('post'), throwsFormatException);
      final files = await Directory('${directory.path}/conversations')
          .list()
          .toList();
      expect(
        jsonDecode(await (files.single as File).readAsString()),
        equals(data),
      );
    },
  );

  test('Tavily uses official search endpoint and configured filters', () async {
    final client = _SearchClient();
    addTearDown(client.close);
    final results = await client.search('资料查询', 'mock-key', {
      'depth': 'advanced',
      'count': 3,
      'timeRange': 'week',
      'includeDomains': ['github.com'],
      'excludeDomains': ['example.net'],
    });
    expect(client.sentUri.toString(), 'https://api.tavily.com/search');
    expect(client.sentBody!['search_depth'], 'advanced');
    expect(client.sentBody!['max_results'], 3);
    expect(client.sentBody!['time_range'], 'week');
    expect(client.sentBody!['include_domains'], ['github.com']);
    expect(results.single['url'], 'https://example.org/article');
  });

  test(
    'published v2 template parses and includes optional platform example',
    () async {
      final snapshot = FeedSnapshot.fromJson(
        jsonDecode(await File('server/feed-v2.example.json').readAsString())
            as Map<String, dynamic>,
      );
      expect(snapshot.items.length, 2);
      expect(snapshot.items.last.platformName, '其他');
    },
  );

  test(
    'folders and trash survive restart and never change original markdown',
    () async {
      await store.saveNote('legacy', '# 原来的笔记\n- [ ] 任务');
      await store.putFolder('folder', '工作');
      await store.moveNote('legacy', 'folder');
      await store.trashNote('legacy');
      expect(await store.loadNotes(), isEmpty);
      final reopened = LocalStore(directory);
      await reopened.init();
      expect(reopened.folders, {'folder': '工作'});
      expect((await reopened.loadNotes(trash: true)).single.folderId, 'folder');
      await reopened.deleteFolder('folder', trashContents: false);
      await reopened.trashNote('legacy', restore: true);
      expect((await reopened.loadNotes()).single.folderId, isNull);
      expect((await reopened.loadNotes()).single.content, '# 原来的笔记\n- [ ] 任务');
      await expectLater(
        reopened.deleteNotePermanently('legacy'),
        throwsFormatException,
      );
      await reopened.trashNote('legacy');
      await reopened.deleteNotePermanently('legacy');
      expect(await reopened.loadNotes(trash: true), isEmpty);
      expect(await reopened.noteFile('legacy').exists(), isFalse);
      await expectLater(
        reopened.trashNote('legacy', restore: true),
        throwsFormatException,
      );
    },
  );

  test('folder deletion moves only its contents and failed mutation preserves metadata', () async {
    await store.saveNote('a', '# A');
    await store.saveNote('b', '# B');
    await store.putFolder('work', '工作');
    await store.putFolder('life', '生活');
    await store.moveNote('a', 'work');
    await store.moveNote('b', 'life');
    await expectLater(store.putFolder('life', '工作'), throwsFormatException);
    expect(store.folders['life'], '生活');
    await store.deleteFolder('work', trashContents: true);
    expect((await store.loadNotes()).single.id, 'b');
    expect((await store.loadNotes(trash: true)).single.id, 'a');
  });

  test(
    'concurrent settings saves retain both updates and legacy source migrates',
    () async {
      await store.setSettings(endpoint: 'https://example.com/feed.json');
      expect(store.subscriptions.single['url'], store.endpoint);
      await Future.wait([
        store.setSettings(extra: {'systemPrompt': '中文'}),
        store.setSettings(
          extra: {
            'subscriptions': [
              {
                'id': 'a',
                'name': '一',
                'url': 'https://example.com/a.json',
                'enabled': true,
              },
            ],
          },
        ),
      ]);
      final reopened = LocalStore(directory);
      await reopened.init();
      expect(reopened.settings['systemPrompt'], '中文');
      expect(reopened.subscriptions.single['id'], 'a');
      await reopened.setSettings(extra: {'subscriptions': []});
      expect(reopened.subscriptions, isEmpty);
    },
  );

  test('v2 accepts arbitrary platform; missing blank and null go to other', () {
    expect(
      FeedSnapshot.fromJson(feed([item('a', platform: 'Mastodon')]))
          .items
          .single
          .platformName,
      'Mastodon',
    );
    for (final data in [
      item('a', url: 'https://github.com/a/b'),
      item('a', platform: ' '),
      {...item('a'), 'platform': null},
    ]) {
      expect(FeedItem.fromJson(data).platformName, '其他');
    }
    expect(
      () => FeedItem.fromJson({...item('a'), 'platform': 2}),
      throwsFormatException,
    );
    expect(
      () => FeedSnapshot.fromJson(feed([item('a'), item('a')])),
      throwsFormatException,
    );
  });

  test('merge deduplicates shared URLs but retains origins and colliding source IDs', () {
    final merged = FeedSnapshot.merge({
      'one': FeedSnapshot.fromJson(
        feed([item('a', url: 'https://example.com/post'), item('collision')]),
      ),
      'two': FeedSnapshot.fromJson(
        feed([item('b', url: 'https://example.com/post'), item('collision')]),
      ),
    });
    expect(merged.items.length, 3);
    expect(merged.items.firstWhere((i) => i.url != null).subscriptionIds, {
      'one',
      'two',
    });
    expect(merged.items.map((i) => i.id).toSet().length, 3);
  });

  test(
    'share filenames sanitize forbidden and reserved names with unicode intact',
    () {
      expect(noteFilename('今天的笔记'), '今天的笔记.md');
      expect(noteFilename('A/B:C?. '), 'A_B_C_.md');
      expect(noteFilename('CON'), '_CON.md');
      expect(noteFilename(''), '未命名笔记.md');
      expect(noteFilename(List.filled(200, '😀').join()).runes.length, 103);
    },
  );

  test('AI parameters cannot overwrite message, model or credentials', () {
    for (final key in [
      'messages',
      'model',
      'stream',
      'api_key',
      'authorization',
      'base_url',
    ]) {
      expect(() => aiParameters(jsonEncode({key: 1})), throwsFormatException);
    }
    expect(() => aiParameters('{"temperature":3}'), throwsFormatException);
    expect(() => aiParameters('[]'), throwsFormatException);
    expect(
      () => reasoningParameters({'max_tokens': 99}, 'thinking', 'high'),
      throwsFormatException,
    );
    expect(reasoningParameters({'max_tokens': 8192}, 'thinking', 'high'), {
      'max_tokens': 8192,
      'thinking': {'type': 'enabled', 'budget_tokens': 4096},
    });
    expect(reasoningParameters({}, 'enable_thinking', 'high'), {
      'enable_thinking': true,
    });
    expect(aiEndpoint('http://example.org/v1').scheme, 'http');
    expect(aiEndpoint('https://example.org/v1/').path, '/v1/chat/completions');
    expect(
      postImages(
        '![a](https://example.com/a.webp) ![b](https://example.com/a.webp) ![c](file:///private)',
      ),
      ['https://example.com/a.webp'],
    );
  });

  test('AI request preserves conversation and vision parts; errors do not echo secret', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    Map<String, dynamic>? body;
    var error = false;
    server.listen((request) async {
      body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      expect(request.headers.value('authorization'), 'Bearer test-key');
      request.response.statusCode = error ? 400 : 200;
      request.response.write(
        error
            ? '{"error":"test-key private-prompt"}'
            : jsonEncode({
                'choices': [
                  {
                    'message': {'content': '你好'},
                  },
                ],
              }),
      );
      await request.response.close();
    });
    final client = AiClient();
    addTearDown(client.close);
    final provider = {
      'baseUrl': 'http://127.0.0.1:${server.port}/v1',
      'model': 'test',
    };
    final messages = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '翻译'},
          {
            'type': 'image_url',
            'image_url': {'url': 'https://example.com/a.webp'},
          },
        ],
      },
    ];
    expect(
      await client.chat(
        provider: provider,
        key: 'test-key',
        messages: messages,
        parameters: {'reasoning_effort': 'high'},
      ),
      '你好',
    );
    expect(body!['messages'], messages);
    expect(body!['reasoning_effort'], 'high');
    error = true;
    try {
      await client.chat(
        provider: provider,
        key: 'test-key',
        messages: messages,
        parameters: {},
      );
      fail('must fail');
    } catch (e) {
      expect('$e', contains('HTTP 400'));
      expect('$e', isNot(contains('test-key')));
      expect('$e', isNot(contains('private-prompt')));
    }
  });
}
