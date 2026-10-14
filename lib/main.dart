import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'custom_fonts.dart';
import 'data_directory.dart';
import 'storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['Little Check'],
      'Copyright (C) 2026 shitianyaa\n\n'
      '${await rootBundle.loadString('assets/ai/AGPL-3.0.txt')}',
    );
    yield LicenseEntryWithLineBreaks(
      ['ai-toolbox model preset data'],
      '${await rootBundle.loadString('assets/ai/NOTICE.txt')}\n\n'
      '${await rootBundle.loadString('assets/ai/AGPL-3.0.txt')}',
    );
  });
  try {
    final location = await DataDirectoryManager.system();
    final store = LocalStore(await location.resolve());
    await store.init();
    await loadStoredFont(store);
    runApp(LittleCheckApp(store: store));
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.folder_off_outlined, size: 36),
                    const SizedBox(height: 16),
                    const Text('无法打开本地数据，原文件已保留'),
                    const SizedBox(height: 8),
                    Text('$error'),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: main, child: const Text('重试')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
