import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

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

  static const _schemaVersion = 1;
  static const _bootstrapName = 'little-check-data-location.json';

  final Directory supportDirectory;

  static Future<DataDirectoryManager> system() async =>
      DataDirectoryManager(await getApplicationSupportDirectory());

  Directory get defaultDirectory =>
      Directory('${supportDirectory.path}${Platform.pathSeparator}LittleCheck');

  File get bootstrapFile =>
      File('${supportDirectory.path}${Platform.pathSeparator}$_bootstrapName');

  String _normalized(Directory directory) {
    var path = directory.absolute.path.replaceAll(
      Platform.isWindows ? '/' : '\\',
      Platform.pathSeparator,
    );
    while (path.length > 1 && path.endsWith(Platform.pathSeparator)) {
      path = path.substring(0, path.length - 1);
    }
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  bool isDefaultDirectory(Directory directory) =>
      _normalized(directory) == _normalized(defaultDirectory);

  Future<Directory> resolve() async {
    final file = bootstrapFile;
    if (!await file.exists()) return defaultDirectory;
    if (await file.length() > 16 * 1024) {
      throw const FormatException('数据目录位置配置过大，原文件已保留');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['schemaVersion'] != _schemaVersion ||
        decoded['path'] is! String ||
        (decoded['path'] as String).trim().isEmpty ||
        (decoded['path'] as String).length > 4096) {
      throw const FormatException('数据目录位置配置损坏，原文件已保留');
    }
    final raw = decoded['path'] as String;
    final absolute = Platform.isWindows
        ? RegExp(r'^(?:[a-zA-Z]:[\\/]|\\\\)').hasMatch(raw)
        : raw.startsWith('/');
    if (!absolute) {
      throw const FormatException('自定义数据目录必须使用绝对路径');
    }
    final directory = Directory(raw).absolute;
    if (!await directory.exists()) {
      throw FormatException('自定义数据目录不存在：${directory.path}');
    }
    return directory;
  }

  Future<void> _saveLocation(Directory directory) async {
    await supportDirectory.create(recursive: true);
    final file = bootstrapFile;
    if (isDefaultDirectory(directory)) {
      if (await file.exists()) await file.delete();
      return;
    }
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schemaVersion': _schemaVersion,
        'path': directory.absolute.path,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<DataMigrationResult> migrate(
    LocalStore store,
    Directory target,
  ) async {
    final destination = target.absolute;
    if (_normalized(store.directory) == _normalized(destination)) {
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
