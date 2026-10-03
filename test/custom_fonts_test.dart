import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/app.dart';
import 'package:little_check/custom_fonts.dart';
import 'package:little_check/storage.dart';

import 'app_test.dart' show finishIO;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('little-check-font-');
    store = LocalStore(directory);
    await store.init();
  });
  tearDown(() async => directory.delete(recursive: true));

  test('default and both legacy font choices use system without destroying settings', () async {
    expect(store.font, 'system');
    for (final value in ['wenkai', 'sans']) {
      await store.setSettings(font: value);
      final reopened = LocalStore(directory);
      await reopened.init();
      expect(reopened.font, 'system');
      expect(reopened.settings['font'], value);
    }
  });

  test(
    'font format and path traversal rejected before creating a copy',
    () async {
      expect(
        () => validateFont(Uint8List.fromList(List.filled(128, 0))),
        throwsFormatException,
      );
      expect(() => customFontFile(store, '../escape'), throwsFormatException);
      final bytes = await File('assets/fonts/NotoSansSC.ttf').readAsBytes();
      final malformed = Uint8List.fromList(bytes);
      ByteData.sublistView(malformed).setUint32(20, bytes.length + 1);
      expect(() => validateFont(malformed), throwsFormatException);
      await expectLater(
        importFont(store, malformed, 'broken.ttf'),
        throwsFormatException,
      );
      expect(await Directory('${directory.path}/fonts').exists(), isFalse);
    },
  );

  test('real font imports, survives restart, and missing/corrupt font has visible fallback', () async {
    final bytes = await File('assets/fonts/NotoSansSC.ttf').readAsBytes();
    final selection = await importFont(store, bytes, '我的字体.ttf');
    await store.setSettings(font: 'custom', extra: {'customFont': selection});
    final reopened = LocalStore(directory);
    await reopened.init();
    await loadStoredFont(reopened);
    expect(reopened.font, 'custom');
    expect(reopened.fontError, isNull);
    expect(reopened.settings['customFont']['name'], '我的字体.ttf');
    final file = customFontFile(store, selection['hash']!);
    expect(await file.length(), bytes.length);
    await file.writeAsBytes(Uint8List.fromList(List.filled(16, 0)));
    await loadStoredFont(reopened);
    expect(reopened.font, 'system');
    expect(reopened.fontError, contains('重新导入'));
    expect(reopened.settings['font'], 'custom');
    await importFont(reopened, bytes, '修复.ttf');
    await loadStoredFont(reopened);
    expect(reopened.font, 'custom');
    expect(reopened.fontError, isNull);
    await file.delete();
    await loadStoredFont(reopened);
    expect(reopened.fontError, isNotNull);
  });

  testWidgets(
    'app theme uses imported family; switching to system persists after restart',
    (tester) async {
      late Map<String, String> selection;
      await finishIO(tester, () async {
        selection = await importFont(
          store,
          await File('assets/fonts/NotoSansSC.ttf').readAsBytes(),
          '测试字体.ttf',
        );
        await store.setSettings(
          font: 'custom',
          extra: {'customFont': selection},
        );
        await tester.pumpWidget(LittleCheckApp(store: store));
      });
      expect(
        Theme.of(tester.element(find.text('Little Check')))
            .textTheme
            .bodyLarge!
            .fontFamily,
        customFontFamily(selection['hash']!),
      );
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('配色与字体'));
      await tester.tap(find.text('配色与字体'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('font:system')));
      await tester.tap(find.byKey(const ValueKey('font:system')));
      await finishIO(tester, () => tester.tap(find.text('保存')));
      expect(store.font, 'system');
      await tester.runAsync(() async {
        final reopened = LocalStore(directory);
        await reopened.init();
        expect(reopened.font, 'system');
      });
      await finishIO(tester, () => tester.pumpWidget(const SizedBox()));
      expect(tester.takeException(), isNull);
    },
  );
}
