import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/ai_page.dart';
import 'package:little_check/app.dart';
import 'package:little_check/external_documents.dart';
import 'package:little_check/feed.dart';
import 'package:little_check/feed_view.dart';
import 'package:little_check/storage.dart';

import 'app_test.dart' show finishIO;
import 'features_test.dart' show feed, item;

class _Http extends HttpOverrides {}

void main() {
  late Directory directory;
  late LocalStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('little-check-new-ui-');
    store = LocalStore(directory);
    await store.init();
    FlutterSecureStorage.setMockInitialValues({'provider:mock': 'mock-key'});
  });
  tearDown(() async => directory.delete(recursive: true));

  testWidgets('two subscription origins combine, filter and isolate failures', (
    tester,
  ) async {
    final old = HttpOverrides.current;
    HttpOverrides.global = _Http();
    addTearDown(() => HttpOverrides.global = old);
    var fail = false;
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    addTearDown(() => server.close(force: true));
    await tester.runAsync(() async {
      server.listen((request) async {
        final one = request.uri.path == '/one';
        request.response.statusCode = one && fail ? 503 : 200;
        request.response.write(
          jsonEncode(
            feed([
              item(
                'shared',
                platform: 'Mastodon',
                url: 'https://example.com/shared',
              ),
              item(
                one
                    ? 'one'
                    : fail
                    ? 'two-new'
                    : 'two',
                platform: one ? '自定义社区' : '博客',
              ),
            ]),
          ),
        );
        await request.response.close();
      });
    });
    await finishIO(tester, () async {
      await store.setSettings(
        extra: {
          'subscriptions': [
            for (final name in ['one', 'two'])
              {
                'id': name,
                'name': name,
                'url': 'http://127.0.0.1:${server.port}/$name',
                'enabled': true,
              },
          ],
        },
      );
      await tester.pumpWidget(LittleCheckApp(store: store));
    });
    expect(find.text('标题 shared'), findsOneWidget);
    expect(find.text('标题 one'), findsOneWidget);
    expect(find.text('标题 two'), findsOneWidget);
    expect(find.text('自定义社区'), findsOneWidget);
    await tester.tap(find.text('全部订阅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('one').last);
    await finishIO(tester);
    expect(find.text('标题 one'), findsOneWidget);
    expect(find.text('标题 two'), findsNothing);
    await tester.tap(find.text('one').first);
    await tester.pumpAndSettle();
    await finishIO(tester, () => tester.tap(find.text('全部订阅').last));
    fail = true;
    await finishIO(
      tester,
      () => tester.state<FeedViewState>(find.byType(FeedView)).refresh(),
    );
    expect(find.textContaining('one：'), findsOneWidget);
    expect(find.text('标题 one'), findsOneWidget);
    expect(find.text('标题 shared'), findsOneWidget);
    final cache = await tester.runAsync(
      () => store.readCache('http://127.0.0.1:${server.port}/two'),
    );
    expect('${cache!['snapshot']}', contains('two-new'));
    await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'AI answer and followup use post context and save local markdown once',
    (tester) async {
      final old = HttpOverrides.current;
      HttpOverrides.global = _Http();
      addTearDown(() => HttpOverrides.global = old);
      final server = (await tester.runAsync(
        () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      ))!;
      addTearDown(() => server.close(force: true));
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        requests.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '这是回复 ${requests.length}'},
              },
            ],
          }),
        );
        await request.response.close();
      });
      var saved = 0;
      await finishIO(tester, () async {
        await store.setSettings(
          extra: {
            'aiProviders': [
              {
                'id': 'mock',
                'name': '演示模型',
                'model': 'demo',
                'baseUrl': 'http://127.0.0.1:${server.port}/v1',
                'vision': true,
              },
            ],
            'defaultProvider': 'mock',
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AiPage(
                item: FeedItem.fromJson(
                  item(
                    'post',
                    platform: 'GitHub',
                    url: 'https://example.com/post',
                  ),
                ),
                store: store,
                onNoteSaved: () => saved++,
              ),
            ),
          ),
        );
      });
      await tester.enterText(find.byType(TextField), '这是什么？');
      await finishIO(tester, () => tester.tap(find.byTooltip('发送')));
      expect(find.textContaining('这是回复 1', findRichText: true), findsOneWidget);
      expect('${requests.first['messages']}', contains('正文'));
      await finishIO(tester, () => tester.tap(find.text('存为笔记')));
      expect(saved, 1);
      final notes = await tester.runAsync(store.loadNotes);
      expect(notes!.single.content, contains('这是回复 1'));
      expect(notes.single.content, contains('https://example.com/post'));
      await tester.enterText(find.byType(TextField), '继续解释');
      await finishIO(tester, () => tester.tap(find.byTooltip('发送')));
      expect('${requests.last['messages']}', contains('这是回复 1'));
      await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('AI controls fit narrow viewport with keyboard and larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(
      () => store.setSettings(
        extra: {
          'aiProviders': [
            {
              'id': 'mock',
              'name': '支持识图的测试模型',
              'model': 'long-model-name',
              'baseUrl': 'https://example.org/v1',
              'vision': true,
            },
          ],
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            viewInsets: const EdgeInsets.only(bottom: 260),
            textScaler: TextScaler.linear(1.3),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: AiPage(
            item: FeedItem.fromJson(item('post')),
            store: store,
            onNoteSaved: () {},
          ),
        ),
      ),
    );
    await finishIO(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cold and warm document signals preview then import without auto saving',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      var batch = <Map<String, String>>[
        {'name': '冷启动.md', 'content': '# 冷启动笔记'},
      ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(documentChannel, (call) async {
            final result = batch;
            batch = [];
            return result;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(documentChannel, null),
      );
      final controller = ExternalDocuments(
        navigator: navigator,
        store: store,
        onSaved: () {},
        enabled: true,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('首页')),
        ),
      );
      controller.start();
      await tester.pumpAndSettle();
      expect(find.text('冷启动.md'), findsOneWidget);
      expect(await tester.runAsync(store.loadNotes), isEmpty);
      await finishIO(tester, () => tester.tap(find.text('导入笔记')));
      expect((await tester.runAsync(store.loadNotes))!.single.title, '冷启动笔记');
      await finishIO(tester, () => tester.tap(find.byTooltip('返回')));
      batch = [
        {'name': '运行中.md', 'content': '# 运行中笔记'},
      ];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        'little_check/documents',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('available'),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(find.text('运行中.md'), findsOneWidget);
      expect((await tester.runAsync(store.loadNotes))!.length, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
      expect(tester.takeException(), isNull);
    },
  );
}
