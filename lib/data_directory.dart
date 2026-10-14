import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'data_location.dart';
import 'storage.dart';

class DataMigrationResult {
  const DataMigrationResult({
    required this.target,
    required this.files,
    required this.bytes,
  });

  final Directory target;
  final int files;
  final int bytes;
}

class DataDirectoryManager {
  DataDirectoryManager(this.supportDirectory);

  final Directory supportDirectory;

  static Future<DataDirectoryManager> system() async =>
      DataDirectoryManager(await getApplicationSupportDirectory());

  Directory get defaultDirectory => defaultDataDirectory(supportDirectory);

  File get bootstrapFile => dataLocationBootstrapFile(supportDirectory);

  bool isDefaultDirectory(Directory directory) =>
      isDefaultDataDirectory(supportDirectory, directory);

  Future<Directory> resolve() => resolveDataDirectory(supportDirectory);

  Future<void> _saveLocation(Directory directory) =>
      writeDataLocationBootstrap(supportDirectory, directory);

  Future<DataMigrationResult> migrate(
    LocalStore store,
    Directory target,
  ) async {
    final destination = target.absolute;
    if (normalizeDirectoryPath(store.directory) ==
        normalizeDirectoryPath(destination)) {
      throw const FormatException('所选目录就是当前数据目录');
    }
    final copied = await store.copyDataTo(destination);
    try {
      await _saveLocation(destination);
    } catch (_) {
      try {
        if (await destination.exists()) {
          await destination.delete(recursive: true);
          await destination.create(recursive: true);
        }
      } catch (_) {
        // The active source remains untouched; preserve the bootstrap error.
      }
      rethrow;
    }
    return DataMigrationResult(
      target: destination,
      files: copied.files,
      bytes: copied.bytes,
    );
  }
}
