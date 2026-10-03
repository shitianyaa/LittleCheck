import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/ai.dart';
import 'package:little_check/ai_page.dart';
import 'package:little_check/app.dart';
import 'package:little_check/feed.dart';
import 'package:little_check/provider_page.dart';
import 'package:little_check/settings_dialog.dart';
import 'package:little_check/storage.dart';

import 'app_test.dart' show finishIO;
import 'features_test.dart' show feed, item;

class _Http extends HttpOverrides {}

void main() {
  late Directory directory;
  late LocalStore store;
  setUp(() async {
    final oldOverride = HttpOverrides.current;
    HttpOverrides.global = _Http();
    addTearDown(() => HttpOverrides.global = oldOverride);
    directory = await Directory.systemTemp.createTemp(
      'little-check-ui-revision-',
    );
    store = LocalStore(directory);
    await store.init();
    FlutterSecureStorage.setMockInitialValues({'provider:p': 'mock-key'});
  });
  tearDown(() async => directory.delete(recursive: true));

  test('three protocols use real model ID, protocol headers, history and image shapes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <Map<String, dynamic>>[];
    server.listen((req) async {
      final body = jsonDecode(
        await utf8.decoder.bind(req).join(),
      ) as Map<String, dynamic>;
      requests.add(body);
      expect(body['model'], 'real-id');
      final protocol = req.uri.path.split('/').last;
      if (protocol == 'messages') {
        expect(req.headers.value('x-api-key'), 'mock-key');
        expect(req.headers.value('anthropic-version'), '2023-06-01');
        expect(req.headers.value('authorization'), isNull);
        expect(body['system'], '中文');
        expect(body['max_tokens'], 3210);
        expect(
          ((body['messages'] as List).first['content'] as List).last,
          equals({
            'type': 'image',
            'source': {'type': 'url', 'url': 'https://example.org/i.png'},
          }),
        );
        req.response.write(
          jsonEncode({
            'content': [
              {'type': 'thinking', 'thinking': '内部思考'},
              {'type': 'text', 'text': 'Messages 回复'},
            ],
          }),
        );
      } else if (protocol == 'responses') {
        expect(req.headers.value('authorization'), 'Bearer mock-key');
        expect(body['messages'], isNull);
        expect(body['max_output_tokens'], 3210);
        expect(body['store'], false);
        expect(
          (body['input'][1]['content'] as List).last,
          equals({
            'type': 'input_image',
            'image_url': 'https://example.org/i.png',
          }),
        );
        req.response.write(
          jsonEncode({
            'output': [
              {'type': 'reasoning', 'summary': []},
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': 'Responses 回复'},
                ],
              },
            ],
          }),
        );
      } else {
        expect(req.headers.value('authorization'), 'Bearer mock-key');
        expect(
          (body['messages'][1]['content'] as List).last,
          equals({
            'type': 'image_url',
            'image_url': {'url': 'https://example.org/i.png'},
          }),
        );
        req.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'Chat 回复'},
              },
            ],
          }),
        );
      }
      await req.response.close();
    });
    final client = AiClient();
    addTearDown(client.close);
    for (final protocol in aiProtocols.keys) {
      final answer = await client.chat(
        provider: {
          'baseUrl': 'http://127.0.0.1:${server.port}/v1/',
          'protocol': protocol,
          'model': 'real-id',
          'alias': '显示别名',
        },
        key: 'mock-key',
        parameters: {'max_tokens': 3210},
        messages: [
          {'role': 'system', 'content': '中文'},
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '问题'},
              {
                'type': 'image_url',
                'image_url': {'url': 'https://example.org/i.png'},
              },
            ],
          },
          {'role': 'assistant', 'content': '前次回复'},
          {'role': 'user', 'content': '继续'},
        ],
      );
      expect(answer, contains('回复'));
    }
    expect(requests.length, 3);
    expect(
      aiEndpoint('http://example.org/custom/', 'responses').path,
      '/custom/responses',
    );
  });

  test(
    'model discovery paginates and does not enable optional parameters',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        expect(req.method, 'GET');
        expect(req.uri.path, '/v1/models');
        final next = req.uri.queryParameters['after_id'] == 'one';
        req.response.write(
          jsonEncode({
            'data': [
              {'id': next ? 'two' : 'one', 'display_name': '别名'},
            ],
            'has_more': !next,
            'last_id': next ? 'two' : 'one',
          }),
        );
        await req.response.close();
      });
      final client = AiClient();
      addTearDown(client.close);
      final models = await client.fetchModels({
        'baseUrl': 'http://127.0.0.1:${server.port}/v1',
        'protocol': 'messages',
      }, 'mock-key');
      expect(models.map((m) => m['id']), ['one', 'two']);
      expect(models.first['parameters'], isEmpty);
      expect(models.first['inheritParameters'], isFalse);
      await store.setSettings(
        extra: {
          'aiProviders': [
            {
              'id': 'p',
              'name': '供应商',
              'baseUrl': 'http://example.org/custom',
              'models': models,
              'protocol': 'messages',
            },
          ],
        },
      );
      final reopened = LocalStore(directory);
      await reopened.init();
      expect(providerModels(providers(reopened).single).length, 2);
    },
  );

  testWidgets(
    'provider validation keeps drafts; HTTP saves without network test',
    (tester) async {
      await tester.pumpWidget(MaterialApp(home: ProviderPage(store: store)));
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '自定义供应商');
      await tester.enterText(fields.at(1), 'wrong-address');
      await finishIO(tester, () => tester.tap(find.text('保存')));
      expect(find.byType(ProviderPage), findsOneWidget);
      expect(tester.widget<TextField>(fields.at(0)).controller!.text, '自定义供应商');
      expect(
        tester.widget<TextField>(fields.at(1)).controller!.text,
        'wrong-address',
      );
      expect(find.textContaining('HTTP(S)'), findsOneWidget);
      await tester.enterText(fields.at(1), 'http://example.org/custom/');
      await finishIO(tester, () => tester.tap(find.text('保存')));
      expect(providers(store).single['baseUrl'], 'http://example.org/custom/');
      expect(providerModels(providers(store).single), isEmpty);
      expect(tester.takeException(), isNull);
      await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
    },
  );

  testWidgets('duplicate model IDs and invalid JSON keep model form input', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ModelPage(protocol: 'chat', existingIds: {'taken'}),
      ),
    );
    await tester.enterText(find.byType(TextField).at(0), 'taken');
    await tester.enterText(find.byType(TextField).at(1), '我的别名');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已存在'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      '我的别名',
    );
    expect(find.byType(ModelPage), findsOneWidget);
  });

  testWidgets(
    'refresh only on entry, explicit refresh or source switch; labels stay separated',
    (tester) async {
      final old = HttpOverrides.current;
      HttpOverrides.global = _Http();
      addTearDown(() => HttpOverrides.global = old);
      final server = (await tester.runAsync(
        () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      ))!;
      addTearDown(() => server.close(force: true));
      var count = 0;
      server.listen((req) async {
        count++;
        req.response.write(jsonEncode(feed([item('post', platform: '社区')])));
        await req.response.close();
      });
      await finishIO(tester, () async {
        await store.setSettings(
          endpoint: 'http://127.0.0.1:${server.port}/feed',
        );
        await tester.pumpWidget(LittleCheckApp(store: store));
      });
      expect(count, 1);
      expect(
        tester.getRect(find.text('订阅来源')).bottom,
        lessThan(tester.getRect(find.text('全部订阅')).top),
      );
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await finishIO(tester, () => tester.tap(find.byTooltip('返回')));
      expect(count, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await finishIO(tester);
      expect(count, 1);
      await finishIO(tester, () async {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      });
      expect(count, 2);
      await tester.tap(find.text('社区'));
      await tester.pumpAndSettle();
      expect(count, 2);
      await finishIO(tester, () => tester.tap(find.text('全部订阅')));
      await finishIO(tester, () => tester.tap(find.text('我的订阅')));
      expect(count, 3);
      await finishIO(tester, () => tester.tap(find.byTooltip('刷新信息流')));
      expect(count, 4);
      await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
    },
  );

  testWidgets('appearance starts at top and trash has a direct entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: SettingsDialog(store: store)));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('外观')).dy, lessThan(130));
    await finishIO(
      tester,
      () => tester.pumpWidget(LittleCheckApp(store: store)),
    );
    await finishIO(tester, () => tester.tap(find.text('笔记').first));
    expect(find.text('回收站'), findsOneWidget);
    await finishIO(tester, () => tester.tap(find.text('回收站')));
    expect(find.text('返回笔记'), findsOneWidget);
    await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
  });

  testWidgets(
    'chat retries in place, persists history and uses model ID not alias',
    (tester) async {
      final old = HttpOverrides.current;
      HttpOverrides.global = _Http();
      addTearDown(() => HttpOverrides.global = old);
      final server = (await tester.runAsync(
        () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      ))!;
      addTearDown(() => server.close(force: true));
      final requests = <Map<String, dynamic>>[];
      server.listen((req) async {
        requests.add(
          jsonDecode(await utf8.decoder.bind(req).join())
              as Map<String, dynamic>,
        );
        req.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '回复 ${requests.length}'},
              },
            ],
          }),
        );
        await req.response.close();
      });
      final post = FeedItem.fromJson(
        item('post', url: 'https://example.org/post'),
      );
      Widget app() => MaterialApp(
        home: Scaffold(
          body: AiPage(item: post, store: store, onNoteSaved: () {}),
        ),
      );
      await finishIO(tester, () async {
        await store.setSettings(
          extra: {
            'aiProviders': [
              {
                'id': 'p',
                'name': '供应商',
                'baseUrl': 'http://127.0.0.1:${server.port}/v1',
                'models': [
                  {
                    'id': 'real-model-id',
                    'alias': '我的模型',
                    'vision': false,
                    'parameters': {},
                    'inheritParameters': false,
                  },
                ],
              },
            ],
          },
        );
        await tester.pumpWidget(app());
      });
      await tester.enterText(find.byType(TextField), '帮我解释');
      await finishIO(tester, () => tester.tap(find.byTooltip('发送')));
      expect(requests.single['model'], 'real-model-id');
      expect(requests.single.containsKey('max_tokens'), isFalse);
      await finishIO(tester, () => tester.tap(find.byTooltip('重新生成回复')));
      expect(find.text('你'), findsOneWidget);
      expect(find.textContaining('回复 2', findRichText: true), findsOneWidget);
      await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
      final saved = await tester.runAsync(
        () => store.readConversation('https://example.org/post'),
      );
      expect((saved!['messages'] as List).length, 2);
      await finishIO(tester, () => tester.pumpWidget(app()));
      expect(find.textContaining('回复 2', findRichText: true), findsOneWidget);
      await tester.enterText(find.byType(TextField), '尚未发送的草稿');
      await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
      await finishIO(tester, () => tester.pumpWidget(app()));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '尚未发送的草稿',
      );
      expect(tester.takeException(), isNull);
      await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
    },
  );
}
