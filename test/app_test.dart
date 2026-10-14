import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/app.dart';
import 'package:little_check/markdown_view.dart';
import 'package:little_check/settings_dialog.dart';
import 'package:little_check/storage.dart';
import 'package:little_check/tasks.dart';
import 'package:little_check/brand_mark.dart';
import 'package:little_check/feed_view.dart';

class _LocalHttpOverrides extends HttpOverrides {}

/// 测试 feed 的发布时间：基于当前时刻的冻结值，避免写死日期随日历推进
/// 超过保留期后被 retainHistory 过滤；全部条目共用同一时间戳以保证排序确定。
final _frozenFeedTime = DateTime.now().toUtc().toIso8601String();

Future<void> finishIO(
  WidgetTester tester, [
  Future<void> Function()? action,
]) async {
  var done = action == null;
  Object? failure;
  StackTrace? failureStack;
  await tester.runAsync(() async {
    if (action != null) {
      // Do not await here: a queued store operation may depend on a callback
      // registered in the widget's fake clock, which needs tester.pump below.
      action().then(
        (_) => done = true,
        onError: (Object error, StackTrace stack) {
          failure = error;
          failureStack = stack;
          done = true;
        },
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  for (var turn = 0; turn < 150; turn++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    if (turn >= 5 && done && !tester.binding.hasScheduledFrame) break;
  }
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  expect(
    done,
    isTrue,
    reason: 'Real IO operation did not finish within the bounded wait',
  );
  await tester.pumpAndSettle();
}

void main() {
  late Directory directory;
  late LocalStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('little-check-ui-');
    store = LocalStore(directory);
    await store.init();
  });
  tearDown(() async => directory.delete(recursive: true));

  testWidgets(
    'platform swipes, section swipes, scroll retention and refresh status',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var fail = false;
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _LocalHttpOverrides();
      addTearDown(() => HttpOverrides.global = previousOverrides);
      final server = (await tester.runAsync(
        () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      ))!;
      addTearDown(() => server.close(force: true));
      final feed = {
        'schema_version': 1,
        'generated_at': _frozenFeedTime,
        'items':
            List.generate(
              30,
              (index) => {
                'id': 'fixture-$index',
                'title': '测试内容 $index',
                'summary': '测试分类与滚动位置',
                'content': '正文',
                'source': '测试来源',
                'platform': 'github',
                'published_at': _frozenFeedTime,
                'url': 'https://github.com/example/repo$index',
              },
            )..add({
              'id': 'pixiv',
              'title': '画作示例',
              'summary': '测试分类',
              'content': '正文',
              'source': '画师',
              'platform': 'pixiv',
              'published_at': _frozenFeedTime,
            }),
      };
      await finishIO(tester, () async {
        server.listen((request) async {
          request.response.statusCode = fail ? 503 : 200;
          if (!fail) request.response.write(jsonEncode(feed));
          await request.response.close();
        });
        await store.setSettings(
          endpoint: 'http://127.0.0.1:${server.port}/feed.json',
        );
        await tester.pumpWidget(LittleCheckApp(store: store));
        await tester
            .state<FeedViewState>(find.byType(FeedView))
            .reloadEndpoint();
      });
      expect(find.textContaining('内容更新于'), findsOneWidget);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 3100)),
      );
      await tester.pump();
      expect(find.textContaining('内容更新于'), findsNothing);
      final platformPages = find.byKey(const ValueKey('platform-pages'));
      await tester.drag(platformPages, const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
      final githubList = find.byKey(const PageStorageKey('feed-list-1'));
      await tester.drag(githubList, const Offset(0, -1200));
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回顶部'), findsOneWidget);
      final controller = tester.widget<ListView>(githubList).controller!;
      final offset = controller.offset;
      await tester.drag(platformPages, const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.text('画作示例'), findsOneWidget);
      expect(find.text('测试内容 0'), findsNothing);
      await tester.drag(platformPages, const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(offset, 1));
      await tester.tap(find.byTooltip('返回顶部'));
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(find.byTooltip('返回顶部'), findsNothing);
      await tester.dragFrom(
        tester.getCenter(find.text('信息流').first),
        const Offset(-250, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('新建笔记'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('main-pages')),
        const Offset(300, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('新建笔记'), findsNothing);
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
      await tester.tap(find.text('其他').first);
      await tester.pumpAndSettle();
      await tester.drag(platformPages, const Offset(-450, 0));
      await tester.pumpAndSettle();
      expect(find.byTooltip('新建笔记'), findsOneWidget);
      await tester.tap(find.text('信息流').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('GitHub').first);
      await tester.pumpAndSettle();
      fail = true;
      await finishIO(
        tester,
        () => tester.state<FeedViewState>(find.byType(FeedView)).refresh(),
      );
      expect(find.textContaining('更新失败，已有内容已保留'), findsOneWidget);
      expect(find.text('测试内容 0'), findsOneWidget);
      expect(find.textContaining('内容更新于'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'creates a note, saves it and toggles the second duplicate task',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await finishIO(
        tester,
        () => tester.pumpWidget(LittleCheckApp(store: store)),
      );
      await tester.tap(find.text('笔记').first);
      await tester.pumpAndSettle();
      await finishIO(tester, () => tester.tap(find.byTooltip('新建笔记')));
      await tester.enterText(
        find.byKey(const ValueKey('note-editor')),
        '# 测试笔记\n\n- [ ] 一样\n- [ ] 一样',
      );
      await finishIO(tester, () => tester.tap(find.byTooltip('保存笔记')));
      final content = '# 测试笔记\n\n- [ ] 一样\n- [ ] 一样';
      final tasks = MarkdownTasks.parse(content);
      expect(find.byType(Checkbox), findsNWidgets(2));
      await finishIO(
        tester,
        () => tester.tap(find.byKey(ValueKey('task:${tasks.last.offset}'))),
      );
      final notes = await tester.runAsync(store.loadNotes);
      expect(notes!.single.content, '# 测试笔记\n\n- [ ] 一样\n- [x] 一样');
      final checkbox = find.byKey(ValueKey('task:${tasks.last.offset}'));
      expect(tester.widget<Checkbox>(checkbox).onChanged, isNotNull);
      await finishIO(tester, () => tester.tap(checkbox));
      expect(
        (await tester.runAsync(store.loadNotes))!.single.content,
        '# 测试笔记\n\n- [ ] 一样\n- [ ] 一样',
      );
      await finishIO(tester, () => tester.tap(checkbox));
      expect(tester.widget<Checkbox>(checkbox).onChanged, isNotNull);
      await finishIO(tester, () => tester.tap(find.byTooltip('返回')));
      expect(
        find.text('测试笔记'),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((widget) => widget.data)
            .join(' | '),
      );
      expect(find.text('1/2 已完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nested and loose task lists retain checkbox source mapping', (
    tester,
  ) async {
    const content = '- [ ] 父项\n  - [ ] 子项\n\n- [ ] 松散列表\n\n  一段文字\n';
    var offset = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownView(
            content: content,
            onToggle: (value) => offset = value,
          ),
        ),
      ),
    );
    final tasks = MarkdownTasks.parse(content);
    expect(find.byType(Checkbox), findsNWidgets(3));
    expect(find.textContaining('父项', findRichText: true), findsWidgets);
    expect(find.textContaining('子项', findRichText: true), findsWidgets);
    expect(find.textContaining('松散列表', findRichText: true), findsWidgets);
    for (final task in tasks) {
      await tester.tap(find.byKey(ValueKey('task:${task.offset}')));
      expect(offset, task.offset);
    }
  });

  testWidgets('feed detail can be saved into a local note on a wide screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await finishIO(
      tester,
      () => tester.pumpWidget(LittleCheckApp(store: store)),
    );
    expect(find.textContaining('示例信息流'), findsOneWidget);
    expect(
      find.text('让信息流回到内容本身'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data)
          .join(' | '),
    );
    await finishIO(tester, () => tester.tap(find.text('让信息流回到内容本身')));
    await finishIO(tester, () => tester.tap(find.byTooltip('保存原帖为笔记')));
    final notes = await tester.runAsync(store.loadNotes);
    expect(notes!.single.title, '让信息流回到内容本身');
    expect(notes.single.content, contains('https://docs.flutter.dev/'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsaved edit survives cancelling back navigation', (
    tester,
  ) async {
    await finishIO(
      tester,
      () => tester.pumpWidget(LittleCheckApp(store: store)),
    );
    await tester.tap(find.text('笔记').first);
    await tester.pumpAndSettle();
    await finishIO(tester, () => tester.tap(find.byTooltip('新建笔记')));
    await tester.enterText(find.byKey(const ValueKey('note-editor')), '# 尚未保存');
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('# 尚未保存'), findsOneWidget);
    expect(await tester.runAsync(store.loadNotes), isEmpty);
  });

  testWidgets('tasks recover interaction after a saving frame', (tester) async {
    void toggle(int _) {}
    Future<void> show(String content, ValueChanged<int>? onToggle) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MarkdownView(content: content, onToggle: onToggle),
            ),
          ),
        );
    await show('- [ ] task', toggle);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNotNull);
    await show('- [x] task', null);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
    await show('- [x] task', toggle);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNotNull);
  });

  testWidgets('task checkbox aligns with its first text line', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownView(content: '- [ ] aligned', onToggle: (_) {}),
        ),
      ),
    );
    final text = find.textContaining('aligned', findRichText: true);
    expect(text, findsOneWidget);
    expect(
      (tester.getCenter(find.byType(Checkbox)).dy - tester.getCenter(text).dy)
          .abs(),
      lessThan(3),
    );
  });

  testWidgets(
    'standalone settings adds and validates subscriptions and appearance',
    (tester) async {
      await finishIO(
        tester,
        () => tester.pumpWidget(LittleCheckApp(store: store)),
      );
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加订阅源'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '测试');
      await tester.enterText(find.byType(TextField).at(1), 'file:///private');
      await finishIO(tester, () => tester.tap(find.text('确定')));
      expect(find.textContaining('完整的 HTTP(S)'), findsOneWidget);
      expect(store.subscriptions, isEmpty);
      await tester.tap(find.text('添加订阅源'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '测试');
      await tester.enterText(
        find.byType(TextField).at(1),
        'https://example.org/feed.json',
      );
      await finishIO(tester, () => tester.tap(find.text('确定')));
      expect(store.subscriptions.single['name'], '测试');
      ScaffoldMessenger.of(tester.element(find.text('设置').first))
          .clearSnackBars();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('配色与字体'), 180);
      await tester.tap(find.text('配色与字体'));
      await tester.pumpAndSettle();
      final themeBounds = tester.getRect(
        find.byKey(const ValueKey('settings-theme')),
      );
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('settings-theme'))),
        themeBounds,
      );
      await tester.tap(find.text('浅色'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('settings-theme'))),
        themeBounds,
      );
      await finishIO(tester, () => tester.tap(find.text('保存')));
      expect(store.theme, 'light');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings labels fit a narrow screen with keyboard and larger text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              viewInsets: const EdgeInsets.only(bottom: 260),
              textScaler: TextScaler.linear(1.3),
            ),
            child: child!,
          ),
          home: SettingsDialog(store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final appearance = tester.getRect(find.text('外观'));
      expect(
        appearance.bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const ValueKey('settings-theme'))).top,
        ),
      );
    },
  );

  testWidgets('format picker inserts a table and selects its first header', (
    tester,
  ) async {
    await finishIO(
      tester,
      () => tester.pumpWidget(LittleCheckApp(store: store)),
    );
    await tester.tap(find.text('笔记').first);
    await tester.pumpAndSettle();
    await finishIO(tester, () => tester.tap(find.byTooltip('新建笔记')));
    await tester.ensureVisible(find.byTooltip('更多格式'));
    await tester.tap(find.byTooltip('更多格式'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('表格'),
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('markdown-format-grid')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('表格'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('note-editor')),
    );
    expect(field.controller!.text, '| 列一 | 列二 |\n| --- | --- |\n| 内容 | 内容 |');
    expect(
      field.controller!.selection.textInside(field.controller!.text),
      '列一',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('palette and font controls save to the application theme', (
    tester,
  ) async {
    await finishIO(
      tester,
      () => tester.pumpWidget(LittleCheckApp(store: store)),
    );
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('配色与字体'),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('配色与字体'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('palette:green')));
    await tester.tap(find.byKey(const ValueKey('palette:green')));
    await tester.ensureVisible(find.byKey(const ValueKey('font:system')));
    await tester.tap(find.byKey(const ValueKey('font:system')));
    await finishIO(tester, () => tester.tap(find.text('保存')));
    expect(store.palette, 'green');
    expect(store.font, 'system');
    final theme = Theme.of(tester.element(find.text('Little Check')));
    expect(theme.colorScheme.primary, const Color(0xFF3D7866));
    expect(theme.textTheme.bodyLarge!.fontFamily, isNot('NotoSansSC'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('brand animation settles and supports reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: BrandMark(animate: true)));
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: BrandMark(animate: true),
        ),
      ),
    );
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('capture light and dark screens', (tester) async {
    if (!const bool.fromEnvironment('CAPTURE_PREVIEWS')) return;
    await tester.runAsync(() async {
      final fonts = [
        (
          'Roboto',
          File(
            '.tools/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
          ),
        ),
        (
          'MaterialIcons',
          File(
            '.tools/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
          ),
        ),
        ('NotoSansSC', File('assets/fonts/NotoSansSC.ttf')),
        ('LXGWWenKai', File('assets/fonts/LXGWWenKai-Regular.ttf')),
      ];
      for (final (family, file) in fonts) {
        if (await file.exists()) {
          final loader = FontLoader(family)
            ..addFont(
              Future.value(ByteData.sublistView(await file.readAsBytes())),
            );
          await loader.load();
        }
      }
      await store.saveNote(
        'preview',
        '# 今天的小事\n\n先把眼前的事情做好。\n\n- [x] 看完今日信息\n- [ ] 留下一个新想法\n- [ ] 晚上出去走走\n\n## 一点记录\n\n喜欢这种安静、清楚的界面。笔记和待办放在一起，想到就写。',
      );
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const key = ValueKey('preview-root');
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
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final folder = Directory('D:/tmp/codex/little-check-next/previews');
        await folder.create(recursive: true);
        await File('${folder.path}/$name.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('feed-light');
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await capture('settings-light');
    await finishIO(tester, () async {
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    });
    await tester.tap(find.text('笔记').first);
    await finishIO(tester);
    await capture('notes-light');
    await finishIO(tester, () => tester.tap(find.text('今天的小事')));
    await capture('note-light');
    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('更多格式'));
    await tester.tap(find.byTooltip('更多格式'));
    await tester.pumpAndSettle();
    await capture('formats-light');
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    await finishIO(tester, () => tester.tap(find.byTooltip('返回')));
    await tester.runAsync(() => store.setSettings(theme: 'dark'));
    await tester.pumpWidget(const SizedBox());
    await finishIO(
      tester,
      () => tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: LittleCheckApp(store: store),
        ),
      ),
    );
    await capture('feed-dark');
    for (final palette in ['green', 'amber', 'violet', 'graphite']) {
      await tester.runAsync(
        () => store.setSettings(theme: 'light', palette: palette),
      );
      await tester.pumpWidget(const SizedBox());
      await finishIO(
        tester,
        () => tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: LittleCheckApp(store: store),
          ),
        ),
      );
      await capture('feed-$palette');
    }
    await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
  });
}
