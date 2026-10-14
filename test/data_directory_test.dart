import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/data_directory.dart';
import 'package:little_check/settings_page.dart';
import 'package:little_check/storage.dart';

void main() {
  late Directory root;
  late Directory support;
  late DataDirectoryManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('little-check-data-location-');
    support = Directory('${root.path}/support');
    manager = DataDirectoryManager(support);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('no bootstrap uses the system default data directory', () async {
    final resolved = await manager.resolve();

    expect(resolved.absolute.path, manager.defaultDirectory.absolute.path);
    expect(await manager.bootstrapFile.exists(), isFalse);
  });

  test(
    'migration copies and verifies data before switching bootstrap',
    () async {
      final source = manager.defaultDirectory;
      final store = LocalStore(source);
      await store.init();
      await store.putFolder('work', '工作');
      await store.saveNote('note', '# 迁移测试\n\n正文');
      await store.moveNote('note', 'work');
      await store.setSettings(extra: {'feedRetentionDays': 30});
      final extra = File('${source.path}/nested/cache.bin');
      await extra.parent.create(recursive: true);
      await extra.writeAsBytes(
        List<int>.generate(4096, (index) => index % 251),
      );

      final target = Directory('${root.path}/custom-data');
      await target.create();
      final result = await manager.migrate(store, target);

      expect(result.files, greaterThanOrEqualTo(4));
      expect(result.bytes, greaterThan(4096));
      expect((await manager.resolve()).absolute.path, target.absolute.path);
      expect(await manager.bootstrapFile.exists(), isTrue);
      expect(await store.noteFile('note').exists(), isTrue);
      expect(await extra.exists(), isTrue);

      final reopened = LocalStore(target);
      await reopened.init();
      final note = (await reopened.loadNotes()).single;
      expect(note.content, '# 迁移测试\n\n正文');
      expect(note.folderId, 'work');
      expect(reopened.folders, {'work': '工作'});
      expect(reopened.feedRetentionDays, 30);
      expect(
        await File('${target.path}/nested/cache.bin').readAsBytes(),
        await extra.readAsBytes(),
      );
    },
  );

  test(
    'non-empty destination is rejected without changing bootstrap',
    () async {
      final store = LocalStore(manager.defaultDirectory);
      await store.init();
      await store.saveNote('note', '# Keep');
      final target = Directory('${root.path}/occupied');
      await target.create();
      final marker = File('${target.path}/keep.txt');
      await marker.writeAsString('unrelated');

      await expectLater(manager.migrate(store, target), throwsFormatException);

      expect(await manager.bootstrapFile.exists(), isFalse);
      expect(await marker.readAsString(), 'unrelated');
      expect(await store.noteFile('note').readAsString(), '# Keep');
    },
  );

  test('an existing bootstrap can be replaced by a later migration', () async {
    final firstStore = LocalStore(manager.defaultDirectory);
    await firstStore.init();
    await firstStore.saveNote('note', '# First');
    final firstTarget = Directory('${root.path}/first-custom');
    await firstTarget.create();
    await manager.migrate(firstStore, firstTarget);

    final reopened = LocalStore(await manager.resolve());
    await reopened.init();
    await reopened.saveNote('note', '# Second');
    final secondTarget = Directory('${root.path}/second-custom');
    await secondTarget.create();
    await manager.migrate(reopened, secondTarget);

    expect((await manager.resolve()).absolute.path, secondTarget.absolute.path);
    expect(
      await File('${secondTarget.path}/notes/note.md').readAsString(),
      '# Second',
    );
    expect(
      await File('${firstTarget.path}/notes/note.md').readAsString(),
      '# Second',
    );
  });

  test(
    'corrupt or missing custom location never silently falls back',
    () async {
      await support.create(recursive: true);
      await manager.bootstrapFile.writeAsString('{bad json');

      await expectLater(manager.resolve(), throwsFormatException);

      await manager.bootstrapFile.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'path': '${root.path}/missing-directory',
        }),
      );
      await expectLater(manager.resolve(), throwsFormatException);
    },
  );

  test('target cannot be inside the active data directory', () async {
    final store = LocalStore(manager.defaultDirectory);
    await store.init();
    await store.saveNote('note', '# Keep');
    final nested = Directory('${store.directory.path}/nested-target');

    await expectLater(manager.migrate(store, nested), throwsFormatException);

    expect(await manager.bootstrapFile.exists(), isFalse);
    expect(await store.noteFile('note').readAsString(), '# Keep');
  });

  testWidgets('windows settings expose data directory controls', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = LocalStore(manager.defaultDirectory);
    await tester.runAsync(store.init);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(store: store, onAppearanceChanged: () {}),
      ),
    );
    await tester.pump();

    expect(find.text('数据存储位置'), findsOneWidget);
    expect(find.text('迁移数据目录'), findsOneWidget);
    expect(find.text(store.directory.path), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('android settings hide windows data directory controls', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = LocalStore(manager.defaultDirectory);
    await tester.runAsync(store.init);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(store: store, onAppearanceChanged: () {}),
      ),
    );
    await tester.pump();

    expect(find.text('数据存储位置'), findsNothing);
    expect(find.text('迁移数据目录'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
}
