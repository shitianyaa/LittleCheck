import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/storage.dart';
import 'package:little_check/sync_identity.dart';
import 'package:little_check/sync_page.dart';

void main() {
  late SyncIdentity identity;
  setUpAll(() async {
    identity = generateSyncIdentity(0);
    if (const bool.fromEnvironment('CAPTURE_SYNC_UI')) {
      final font = FontLoader('CaptureChinese')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File('assets/fonts/NotoSansSC.ttf').readAsBytes(),
            ),
          ),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                'D:/Project/LittleCheckSDK/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes(),
            ),
          ),
        );
      await icons.load();
    }
  });
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'sync page fits narrow ${platform.name} and offers pairing controls',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        FlutterSecureStorage.setMockInitialValues({
          'littlecheck-lan-identity-v1': jsonEncode({
            'deviceId': identity.deviceId,
            'certificate': identity.certificate,
            'privateKey': identity.privateKey,
          }),
        });
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('sync-ui-test-'),
        ))!;
        final store = LocalStore(directory);
        await tester.runAsync(store.init);
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              fontFamily: const bool.fromEnvironment('CAPTURE_SYNC_UI')
                  ? 'CaptureChinese'
                  : null,
            ),
            home: RepaintBoundary(
              key: key,
              child: SyncPage(store: store),
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
        }
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.text('设备同步'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (platform == TargetPlatform.android) {
          expect(find.text('扫描电脑二维码'), findsOneWidget);
          expect(find.text('手动输入配对信息'), findsOneWidget);
          await tester.tap(find.text('手动输入配对信息'));
          await tester.pumpAndSettle();
          expect(find.text('输入配对信息'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
        } else {
          expect(find.text('开启局域网同步'), findsOneWidget);
        }
        if (const bool.fromEnvironment('CAPTURE_SYNC_UI')) {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final output = Directory(
              'D:/tmp/codex/little-check-lan-sync/screenshots',
            );
            await output.create(recursive: true);
            await File('${output.path}/${platform.name}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => directory.delete(recursive: true));
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
