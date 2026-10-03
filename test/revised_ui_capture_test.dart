import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:little_check/app.dart';
import 'package:little_check/brand_mark.dart';
import 'package:little_check/storage.dart';

import 'features_test.dart' show feed, item;

class _Http extends HttpOverrides {}

Future<void> finishIO(
  WidgetTester tester, [
  Future<void> Function()? action,
]) async {
  await tester.runAsync(() async {
    if (action != null) await action();
  });
  for (var i = 0; i < 16; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 80));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('revised controls and inline translation summary screenshots', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('CAPTURE_REVISED_UI')) return;
    final old = HttpOverrides.current;
    HttpOverrides.global = _Http();
    addTearDown(() => HttpOverrides.global = old);
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('little-check-capture-'),
    ))!;
    final store = (await tester.runAsync(() async {
      final s = LocalStore(directory);
      await s.init();
      return s;
    }))!;
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    addTearDown(() => server.close(force: true));
    addTearDown(() => directory.delete(recursive: true));
    final data = feed([
      {
        ...item('post', platform: 'GitHub', url: 'https://example.org/post'),
        'title': '一个值得收藏的开源项目',
        'summary': '让信息流与 Markdown 笔记保持简单，随时留下想法。',
        'content': '## What this project does\n\nRead feeds and keep local Markdown notes.\n\n- Fast reading\n- Simple writing',
      },
    ]);
    server.listen((req) async {
      if (req.method == 'POST') {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        final summary = '${body['messages']}'.contains('本次动作：总结');
        req.response.write(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {
                  'content': summary
                      ? '## 重点\n\n- 聚合订阅内容，快速阅读。\n- 本地保存 Markdown 笔记。\n\n适合希望简化阅读与记录的人。'
                      : '## 这个项目可以做什么\n\n阅读信息流并保存本地 Markdown 笔记。\n\n- 快速阅读\n- 简洁记录',
                },
              },
            ],
          }),
        );
      } else {
        req.response.write(jsonEncode(data));
      }
      await req.response.close();
    });
    await tester.runAsync(() async {
      // Supply a CJK rendering font to the widget test engine; it is not an APK asset.
      final font = FontLoader('Roboto')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File('assets/fonts/NotoSansSC.ttf').readAsBytes(),
            ),
          ),
        );
      await font.load();
      final icons = File(
        'D:/Project/LittleCheckSDK/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (await icons.exists()) {
        final loader = FontLoader('MaterialIcons')
          ..addFont(
            Future.value(ByteData.sublistView(await icons.readAsBytes())),
          );
        await loader.load();
      }
      await store.init();
      await store.setSettings(
        endpoint: 'http://127.0.0.1:${server.port}/feed',
        extra: {
          'aiProviders': [
            {
              'id': 'p',
              'name': '我的供应商',
              'baseUrl': 'http://127.0.0.1:${server.port}/v1',
              'models': [
                {
                  'id': 'example-model',
                  'alias': '日常助手',
                  'vision': false,
                  'parameters': {},
                  'inheritParameters': false,
                },
              ],
            },
          ],
        },
      );
      FlutterSecureStorage.setMockInitialValues({'provider:p': 'test-fixture'});
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const key = ValueKey('capture-revised');
    await finishIO(
      tester,
      () => tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: LittleCheckApp(store: store),
        ),
      ),
    );
    Future<void> capture(String name) async {
      await tester.runAsync(() async {
        final render = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        final image = await render.toImage(pixelRatio: 2);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('D:/tmp/claude/little-check-topbar-preview/$name.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.pump(const Duration(seconds: 4));
    await capture('feed-after');
    final update = find.textContaining('内容更新于');
    expect(tester.getCenter(update).dx, closeTo(195, 1));
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '开源');
    await tester.pumpAndSettle();
    await capture('search-active');
    await tester.tap(find.byTooltip('退出搜索'));
    await tester.pumpAndSettle();
    await finishIO(tester, () => tester.tap(find.text('笔记').first));
    await capture('notes-after');
    await tester.tap(find.byTooltip('管理文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建文件夹'));
    await tester.pumpAndSettle();
    await capture('folder-sheet');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await finishIO(tester, () => tester.tap(find.text('信息流').first));
    await tester.tap(find.text('全部订阅'));
    await tester.pumpAndSettle();
    await capture('selection-after');
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('配色与字体'));
    await tester.pumpAndSettle();
    await capture('appearance-after');
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await finishIO(tester, () => tester.tap(find.text('我的供应商')));
    await capture('provider-after');
    await tester.tap(find.text('日常助手 · example-model'));
    await tester.pumpAndSettle();
    await capture('model-after');
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await finishIO(tester, () => tester.tap(find.byTooltip('返回')));
    await finishIO(tester, () => tester.tap(find.text('一个值得收藏的开源项目')));
    expect(find.byTooltip('问 AI'), findsNothing);
    await capture('reading-after');
    await finishIO(tester, () => tester.tap(find.text('翻译')));
    expect(
      find.textContaining('阅读信息流并保存本地', findRichText: true),
      findsOneWidget,
    );
    await capture('translation-after');
    await finishIO(tester, () => tester.tap(find.text('总结')));
    expect(find.text('AI 总结'), findsOneWidget);
    expect(find.textContaining('适合希望简化', findRichText: true), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await capture('summary-after');
    await finishIO(tester, () => tester.tap(find.byTooltip('存为笔记').last));
    final notes = (await tester.runAsync(store.loadNotes))!;
    expect(store.folders[notes.single.folderId], 'AI 总结');
    expect(tester.takeException(), isNull);

    const iconKey = ValueKey('capture-icon');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: RepaintBoundary(
              key: iconKey,
              child: Container(
                padding: const EdgeInsets.all(24),
                color: const Color(0xFFF6F8FA),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 108,
                      height: 108,
                      decoration: BoxDecoration(
                        color: const Color(0xFF4F7693),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Theme(
                        data: ThemeData(
                          colorScheme: const ColorScheme.light(
                            primary: Colors.white,
                          ),
                        ),
                        child: const Center(
                          child: BrandMark(size: 64, animate: false),
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    Container(
                      width: 108,
                      height: 108,
                      decoration: const BoxDecoration(
                        color: Color(0xFF4F7693),
                        shape: BoxShape.circle,
                      ),
                      child: Theme(
                        data: ThemeData(
                          colorScheme: const ColorScheme.light(
                            primary: Colors.white,
                          ),
                        ),
                        child: const Center(
                          child: BrandMark(size: 64, animate: false),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final render = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(iconKey),
      );
      final image = await render.toImage(pixelRatio: 2);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File('D:/tmp/claude/little-check-topbar-preview/icon-preview.png')
          .writeAsBytes(bytes.buffer.asUint8List());
      image.dispose();
    });

    await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
  });
}
