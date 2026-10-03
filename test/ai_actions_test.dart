import 'dart:convert';
import 'dart:async';
import 'dart:io' as io;

import 'package:file/file.dart' show File;
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/ai.dart';
import 'package:little_check/ai_actions.dart';
import 'package:little_check/action_settings_page.dart';
import 'package:little_check/ai_action_view.dart';
import 'package:little_check/ai_keys.dart';
import 'package:little_check/model_presets.dart';
import 'package:little_check/provider_page.dart';
import 'package:little_check/storage.dart';

import 'app_test.dart' show finishIO;
import 'features_test.dart' show item;

import 'package:little_check/feed.dart';

class _Client extends AiClient {
  int calls = 0, readmes = 0;
  bool readmeFails = false;
  List<Map<String, dynamic>>? sentMessages;
  Map<String, dynamic>? sentProvider;
  Map<String, dynamic>? sentParameters;
  String readmeText = '# 项目 README\n\n真实补充资料';
  @override
  Future<Map<String, dynamic>> publicJson(Uri uri) async {
    readmes++;
    expect(uri.host, 'api.github.com');
    expect(uri.path, '/repos/owner/repo/readme');
    if (readmeFails) throw const FormatException('模拟 README 不可用');
    return {
      'encoding': 'base64',
      'content': base64Encode(utf8.encode(readmeText)),
    };
  }

  @override
  Future<String> chat({
    required Map<String, dynamic> provider,
    required String key,
    required List<Map<String, dynamic>> messages,
    required Map<String, dynamic> parameters,
  }) async {
    calls++;
    sentProvider = provider;
    sentMessages = messages;
    sentParameters = parameters;
    expect(key, isNotEmpty);
    return '## 结果\n\n第一段\n\n- 重点一\n- 重点二';
  }
}

class _Http extends io.HttpOverrides {}

class _Files implements FileSystem {
  _Files(this.path);
  final String path;
  @override
  Future<File> createFile(String name) async =>
      const LocalFileSystem().file('$path/$name');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late io.Directory directory;
  late LocalStore store;
  final post = FeedItem.fromJson({
    ...item('p', url: 'https://github.com/owner/repo'),
    'title': '项目标题',
    'content': '原文\n\n```dart\ncode\n```',
  });
  setUp(() async {
    directory = await io.Directory.systemTemp.createTemp(
      'little-check-actions-',
    );
    store = LocalStore(directory);
    await store.init();
    FlutterSecureStorage.setMockInitialValues({'provider:p': 'test-key'});
    store.settings = {
      'systemPrompt': '不应该发送的旧人设：蓝色圆环',
      'aiProviders': [
        {
          'id': 'p',
          'name': '测试服务',
          'baseUrl': 'http://example.org/v1',
          'protocol': 'chat',
          'models': [
            {
              'id': 'real-id',
              'alias': '显示名',
              'vision': true,
              'parameters': {},
              'inheritParameters': false,
            },
          ],
        },
      ],
    };
  });
  tearDown(() async => directory.delete(recursive: true));

  test('actions use independent prompts, explicit task and README; cached results avoid calls', () async {
    await store.setSettings(
      extra: {
        'actionPrompts': {
          'translate': '自定义翻译 {action} {target_lang}\n{source_text}',

          'summary': '自定义总结\n{source_text}',
        },
      },
    );
    for (final action in AiAction.values) {
      final client = _Client();
      final active = AiActionService(store, client: client);
      addTearDown(active.close);
      final result = await active.run(post, action);
      expect(result['action'], action.name);
      expect(client.calls, 1);
      final text = client.sentMessages!.last['content'] as String;
      expect(text, contains('本次动作：${action.label}'));
      expect(text, contains('真实补充资料'));
      expect(text, contains('code\n```'));
      expect(jsonEncode(client.sentMessages), isNot(contains('蓝色圆环')));
      expect(client.sentProvider!['model'], 'real-id');
      expect(await active.run(post, action), equals(result));
      expect(client.calls, 1);
    }
    final reopened = LocalStore(directory);
    await reopened.init();
    final offline = AiActionService(reopened, client: _Client());
    addTearDown(offline.close);
    expect(await offline.cached(post, AiAction.summary, []), isNotNull);
  });

  test(
    'latest results persist despite refreshed titles and removed providers',
    () async {
      final service = AiActionService(store, client: _Client());
      addTearDown(service.close);
      final result = await service.run(post, AiAction.summary);
      expect(result['durationMs'], isA<int>());
      final changed = FeedItem.fromJson({
        ...item('p', url: 'https://github.com/owner/repo'),
        'title': '热度变化后的标题',
      });
      final reopened = LocalStore(directory);
      await reopened.init();
      final offline = AiActionService(reopened, client: _Client());
      addTearDown(offline.close);
      final restored = await offline.previousResult(changed, AiAction.summary);
      expect(restored!['text'], result['text']);
      expect(restored['previousVersion'], true);
      await reopened.setSettings(extra: {'aiProviders': []});
      expect(
        (await offline.previousResult(changed, AiAction.summary))!['text'],
        result['text'],
      );
    },
  );

  test('specialist choices inherit main when absent and route image tasks to vision model', () async {
    final list = providers(store);
    list.single['models'] = [
      ...providerModels(list.single),
      {
        'id': 'translator',
        'alias': '',
        'vision': false,
        'parameters': {},
        'inheritParameters': false,
      },
    ];
    await store.setSettings(
      extra: {
        'aiProviders': list,
        'actionModels': {
          'main': {'providerId': 'p', 'modelId': 'real-id'},
          'translation': {'providerId': 'p', 'modelId': 'translator'},
          'vision': null,
        },
      },
    );
    expect(
      actionModel(store, action: AiAction.translate).model['id'],
      'translator',
    );
    expect(actionModel(store, action: AiAction.summary).model['id'], 'real-id');
    expect(
      actionModel(store, action: AiAction.translate, images: true).model['id'],
      'real-id',
    );
    await store.setSettings(
      extra: {
        'actionModels': {
          'main': {'providerId': 'p', 'modelId': 'translator'},
        },
      },
    );
    expect(
      () => actionModel(store, action: AiAction.summary, images: true),
      throwsFormatException,
    );
  });

  test('multi key rotation excludes disabled keys and settings contain metadata only', () async {
    FlutterSecureStorage.setMockInitialValues({
      'provider:pool:a': 'key-a',
      'provider:pool:b': 'key-b',
      'provider:pool:c': 'key-c',
    });
    final pool = {
      'id': 'pool',
      'keys': [
        {'id': 'a', 'name': 'A', 'enabled': true},
        {'id': 'b', 'name': 'B', 'enabled': false},
        {'id': 'c', 'name': 'C', 'enabled': true},
      ],
    };
    expect(await nextProviderKey(pool), 'key-a');
    expect(await nextProviderKey(pool), 'key-c');
    expect(await nextProviderKey(pool), 'key-a');
    await expectLater(
      nextProviderKey({'id': 'empty', 'keys': []}),
      throwsFormatException,
    );
    final bad = providers(store).single
      ..['keys'] = [
        {'id': 'a', 'name': 'A', 'enabled': true, 'value': 'bad'},
      ];
    await expectLater(
      store.setSettings(
        extra: {
          'aiProviders': [bad],
        },
      ),
      throwsFormatException,
    );
  });

  test('default thinking uses preset protocol mapping and README updates invalidate cached answers', () async {
    final preset = (await loadModelPresets()).firstWhere(
      (p) => p['id'] == 'gpt-5.6-luna',
    );
    final list = providers(store);
    list.single['models'] = [
      applyModelPreset({'id': 'real-id'}, preset, 'responses'),
    ];
    await store.setSettings(
      extra: {
        'aiProviders': list,
        'actionReasoning': 'low',
        'actionParameters': {'max_tokens': 16000},
      },
    );
    final client = _Client(),
        service = AiActionService(store, client: _Client());
    service.close();
    final active = AiActionService(store, client: client);
    addTearDown(active.close);
    await active.run(post, AiAction.summary);
    expect(client.sentParameters!['reasoning'], {'effort': 'low'});
    expect(client.sentParameters!['max_tokens'], 8192);
    client.readmeText = '# 新版资料';
    await active.readme(post, force: true);
    expect(await active.cached(post, AiAction.summary, []), isNull);
    await active.run(post, AiAction.summary);
    expect(client.calls, 2);
    expect(client.sentMessages!.last['content'], contains('新版资料'));
  });

  test('three protocols carry actual image data; refusals, truncated answers and bad JSON are diagnosed', () async {
    final old = io.HttpOverrides.current;
    io.HttpOverrides.global = _Http();
    addTearDown(() => io.HttpOverrides.global = old);
    final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var mode = 'blocks';
    const image = 'data:image/png;base64,iVBORw0KGgo=';
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body['model'], 'real-id');
      final protocol = request.uri.path.split('/').last;
      Object response;
      if (protocol == 'messages') {
        expect(body['max_tokens'], 555);
        expect(body['messages'][0]['content'][1]['source'], {
          'type': 'base64',
          'media_type': 'image/png',
          'data': 'iVBORw0KGgo=',
        });
        expect(request.headers.value('x-api-key'), 'fixture-key');
        response = {
          'content': [
            {'type': 'text', 'text': '文字回复'},
          ],
          'stop_reason': 'end_turn',
        };
      } else if (protocol == 'responses') {
        expect(body['max_output_tokens'], 555);
        expect(body['store'], false);
        expect(body['reasoning'], {'summary': 'auto', 'effort': 'low'});
        expect(body['input'][0]['content'][1]['image_url'], image);
        response = {
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': '文字回复'},
              ],
            },
          ],
        };
      } else {
        expect(body['max_completion_tokens'], 555);
        expect(body.containsKey('max_tokens'), false);
        response = {
          'choices': [
            {
              'finish_reason': mode == 'length' ? 'length' : 'stop',
              'message': mode == 'refusal'
                  ? {'refusal': 'refused'}
                  : mode == 'thinking'
                  ? {'content': null, 'reasoning_content': '仅有思考'}
                  : {
                      'content': [
                        {'type': 'text', 'text': '第一段'},
                        {'type': 'text', 'text': '第二段'},
                      ],
                    },
            },
          ],
        };
      }
      request.response.write(
        mode == 'bad-json'
            ? 'invalid JSON with fixture-key'
            : jsonEncode(response),
      );
      await request.response.close();
    });
    final client = AiClient();
    addTearDown(client.close);
    Future<String> send(String protocol) => client.chat(
      provider: {
        'baseUrl': 'http://127.0.0.1:${server.port}/v1',
        'protocol': protocol,
        'model': 'real-id',
      },
      key: 'fixture-key',
      parameters: protocol == 'chat'
          ? {'max_tokens': 444, 'max_completion_tokens': 555}
          : protocol == 'responses'
          ? {
              'max_tokens': 444,
              'max_output_tokens': 555,
              'reasoning': {'summary': 'auto'},
              'reasoning_effort': 'low',
            }
          : {'max_output_tokens': 555},
      messages: [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '识图'},
            {
              'type': 'image_url',
              'image_url': {'url': image},
            },
          ],
        },
      ],
    );
    expect(await send('chat'), '第一段\n第二段');
    expect(await send('responses'), '文字回复');
    expect(await send('messages'), '文字回复');
    for (final scenario in {
      'length': '输出长度',
      'refusal': '拒绝',
      'thinking': '没有返回正文',
      'bad-json': 'JSON 无效',
    }.entries) {
      mode = scenario.key;
      await expectLater(
        send('chat'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'diagnostic',
            contains(scenario.value),
          ),
        ),
      );
    }
  });

  test('model presets preserve gateway IDs, map variants and keep limits separate from output defaults', () async {
    final presets = await loadModelPresets();
    expect(presets.length, 102);
    final gpt = presets.firstWhere((p) => p['id'] == 'gpt-5.6-luna');
    final configured = applyModelPreset(
      {'id': 'custom-gateway-name'},
      gpt,
      'responses',
    );
    expect(configured['id'], 'custom-gateway-name');
    expect(configured['vision'], true);
    expect(configured['parameters']['max_tokens'], 8192);
    expect(configured['capabilities']['outputLimit'], 128000);
    expect(presetParameters(gpt, 'responses', 'low')['reasoning'], {
      'effort': 'low',
    });
    expect(presetParameters(gpt, 'chat', 'low')['reasoning_effort'], 'low');
    final google = presets.firstWhere((p) => p['id'] == 'gemini-2.5-flash');
    expect(
      presetParameters(
        google,
        'chat',
        'no-thinking',
      ).containsKey('thinkingConfig'),
      false,
    );
    final claude = presets.firstWhere((p) => p['id'] == 'claude-sonnet-4-6');
    expect(presetParameters(claude, 'messages', 'high')['output_config'], {
      'effort': 'high',
    });
    expect(() => validateActionPrompt('翻译 {unknown}'), throwsFormatException);
  });

  test(
    'README failure is visible and export reuses folders without ID collisions',
    () async {
      final client = _Client()..readmeFails = true;
      final service = AiActionService(store, client: client);
      addTearDown(service.close);
      final result = await service.run(post, AiAction.summary);
      expect(result['notice'], contains('README 获取失败'));
      expect(client.sentMessages!.last['content'], contains('资料未获取成功'));
      await store.putFolder('ai_summary', '已有文件夹');
      final note = await store.saveAiNote(
        'summary',
        '总结笔记',
        result['text'] as String,
      );
      expect(store.folders.values.toSet(), {'已有文件夹', 'AI 翻译', 'AI 总结'});
      expect(note.folderId, isNot('ai_summary'));
      expect((await store.loadNotes()).single.folderId, note.folderId);
      await store.saveAiNote('summary', '第二篇', '内容');
      expect(store.folders.length, 3);
    },
  );

  test('actual cached image bytes become a data URL and malformed images stop the action', () async {
    final cache = CacheManager(
      Config(
        'action-fixture',
        repo: JsonCacheInfoRepository(path: '${directory.path}/images.json'),
        fileSystem: _Files(directory.path),
      ),
    );
    addTearDown(cache.dispose);
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAAM0lEQVR4nO3RwQ0AMAjDwJTJGb0jmE9+vgGCZF6yaZrqejxw4A+QiZCJkImQiZCJUD3RB24jALCu/Sv2AAAAAElFTkSuQmCC',
    );
    const url = 'https://example.org/image.png';
    await cache.putFile(url, bytes, fileExtension: 'png');
    final client = _Client();
    final active = AiActionService(store, client: client, imageCache: cache);
    addTearDown(active.close);
    await active.run(post, AiAction.translate, images: [url]);
    expect(await active.previousImages(post, AiAction.translate), [url]);
    expect(await active.cached(post, AiAction.translate, [url]), isNotNull);
    final parts = client.sentMessages!.last['content'] as List;
    final data = parts.last['image_url']['url'] as String;
    expect(data, startsWith('data:image/png;base64,'));
    expect(base64Decode(data.split(',').last), isNotEmpty);
    expect(parts.first['text'], contains('实际附加图片数量：1'));
    await cache.putFile(
      'https://example.org/bad.png',
      utf8.encode('invalid image'),
      fileExtension: 'png',
    );
    await expectLater(
      active.run(
        post,
        AiAction.summary,
        images: ['https://example.org/bad.png'],
      ),
      throwsFormatException,
    );
    expect(client.calls, 1);
  });

  testWidgets(
    'pausing preserves the saved result and restarting records total duration',
    (tester) async {
      final gate = Completer<void>(), started = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final oldHttp = io.HttpOverrides.current;
      io.HttpOverrides.global = _Http();
      addTearDown(() => io.HttpOverrides.global = oldHttp);
      final server = (await tester.runAsync(
        () => io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0),
      ))!;
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        if (!started.isCompleted) started.complete();
        await gate.future;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {'content': '新总结'},
              },
            ],
          }),
        );
        await request.response.close();
      });
      final localPost = FeedItem.fromJson(
        item('pause', url: 'https://example.org/post'),
      );
      await tester.runAsync(() async {
        final initial = store.settings;
        store = LocalStore(directory);
        await store.init();
        final configured = (initial['aiProviders'] as List).single as Map;
        configured['baseUrl'] = 'http://127.0.0.1:${server.port}/v1';
        await store.setSettings(extra: initial);
        final service = AiActionService(store);
        final cacheId = service.cacheKey(localPost, AiAction.summary, []);
        await store.saveTranslation(cacheId, {
          'text': '原有总结',
          'model': '测试模型',
          'notice': '',
          'durationMs': 1500,
          'cacheId': cacheId,
        });
        await store.saveActionImages(
          service.selectionIdentity(localPost, AiAction.summary),
          [],
          cacheId: cacheId,
        );
        service.close();
      });
      final key = GlobalKey<AiActionResultState>();
      await finishIO(
        tester,
        () => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AiActionResult(
                key: key,
                item: localPost,
                store: store,
                action: AiAction.summary,
                onNoteSaved: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('总用时 1.5 秒'), findsOneWidget);
      await tester.runAsync(() async {
        unawaited(key.currentState!.run(force: true));
      });
      for (var i = 0; i < 60 && !started.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(started.isCompleted, true);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byTooltip('暂停总结'));
      await tester.pump();
      expect(find.textContaining('已暂停'), findsOneWidget);
      expect(find.textContaining('原有总结', findRichText: true), findsOneWidget);
      gate.complete();
      await tester.tap(find.text('重新开始'));
      // Keep real HTTP/file IO progressing before settling the busy animation.
      for (
        var turn = 0;
        turn < 200 &&
            find.textContaining('新总结', findRichText: true).evaluate().isEmpty;
        turn++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.textContaining('新总结', findRichText: true), findsOneWidget);
      expect(find.textContaining('总用时'), findsOneWidget);
      await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
    },
  );

  testWidgets(
    'action settings retain invalid prompts and save independent prompts on a narrow screen',
    (tester) async {
      await tester.runAsync(() async {
        final initial = store.settings;
        store = LocalStore(directory);
        await store.init();
        await store.setSettings(extra: initial);
      });
      await tester.binding.setSurfaceSize(const Size(360, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: ActionSettingsPage(store: store),
        ),
      );
      await tester.pumpAndSettle();
      final prompt = find.byKey(const ValueKey('prompt:translate'));
      await tester.scrollUntilVisible(
        prompt,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(prompt, '翻译 {unknown}');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(prompt).controller!.text, '翻译 {unknown}');
      expect(store.settings['actionPrompts'], isNull);
      expect(tester.takeException(), isNull);
      await tester.enterText(prompt, '独立翻译 {source_text}');
      await finishIO(tester, () => tester.tap(find.text('保存')));
      expect(
        store.settings['actionPrompts']['translate'],
        '独立翻译 {source_text}',
      );
      expect(
        store.settings['actionPrompts']['summary'],
        isNot('独立翻译 {source_text}'),
      );
      expect(store.settings['actionModels']['main']['modelId'], 'real-id');
      await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
    },
  );

  testWidgets(
    'provider keys are visible, eye toggles and legacy key survives staged migration',
    (tester) async {
      await tester.runAsync(() async {
        final initial = store.settings;
        store = LocalStore(directory);
        await store.init();
        await store.setSettings(extra: initial);
      });
      final provider = providers(store).single;
      await finishIO(
        tester,
        () => tester.pumpWidget(
          MaterialApp(
            home: ProviderPage(store: store, provider: provider),
          ),
        ),
      );
      final key = find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == 'test-key',
      );
      expect(key, findsOneWidget);
      expect(tester.widget<TextField>(key).obscureText, false);
      await tester.ensureVisible(find.byTooltip('隐藏 Key'));
      await tester.tap(find.byTooltip('隐藏 Key'));
      await tester.pump();
      expect(tester.widget<TextField>(key).obscureText, true);
      await finishIO(tester, () => tester.tap(find.text('保存')));
      await tester.runAsync(() async {
        final updated = providers(store).single;
        expect(providerKeys(updated).length, 1);
        expect(await nextProviderKey(updated), 'test-key');
        expect(await secureKeys.read(key: 'provider:p'), 'test-key');
        expect(
          await io.File('${directory.path}/settings.json').readAsString(),
          isNot(contains('test-key')),
        );
      });
      expect(find.textContaining('models.dev'), findsNothing);
      await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
    },
  );
}
