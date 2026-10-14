// 数据目录定位的纯 Dart 逻辑，供 App（DataDirectoryManager）与命令行工具
// （bin/lck.dart）共用，避免两处 bootstrap 解析逻辑漂移。
//
// 本文件不得依赖 Flutter：lck 以纯 Dart 运行，无法使用 path_provider 等插件。

import 'dart:convert';
import 'dart:io';

const dataLocationSchemaVersion = 1;
const dataLocationBootstrapName = 'little-check-data-location.json';

/// 规范化目录路径用于比较：统一分隔符、去尾部分隔符；Windows 下忽略大小写。
String normalizeDirectoryPath(Directory directory) {
  var path = directory.absolute.path.replaceAll(
    Platform.isWindows ? '/' : '\\',
    Platform.pathSeparator,
  );
  while (path.length > 1 && path.endsWith(Platform.pathSeparator)) {
    path = path.substring(0, path.length - 1);
  }
  return Platform.isWindows ? path.toLowerCase() : path;
}

/// 默认数据目录：`<support>/LittleCheck`。
Directory defaultDataDirectory(Directory supportDirectory) =>
    Directory('${supportDirectory.path}${Platform.pathSeparator}LittleCheck');

/// bootstrap 文件：记录当前用户数据的绝对路径，固定留在 support 目录根。
File dataLocationBootstrapFile(Directory supportDirectory) => File(
  '${supportDirectory.path}${Platform.pathSeparator}$dataLocationBootstrapName',
);

bool isDefaultDataDirectory(Directory supportDirectory, Directory directory) =>
    normalizeDirectoryPath(directory) ==
    normalizeDirectoryPath(defaultDataDirectory(supportDirectory));

/// 解析当前数据目录：读 bootstrap，无则用默认目录。
/// bootstrap 损坏或指向不存在目录时明确抛错，不静默回退，避免「数据像丢了」。
Future<Directory> resolveDataDirectory(Directory supportDirectory) async {
  final file = dataLocationBootstrapFile(supportDirectory);
  if (!await file.exists()) return defaultDataDirectory(supportDirectory);
  if (await file.length() > 16 * 1024) {
    throw const FormatException('数据目录位置配置过大，原文件已保留');
  }
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map<String, dynamic> ||
      decoded['schemaVersion'] != dataLocationSchemaVersion ||
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

/// 写入 bootstrap：指向默认目录时删除 bootstrap，否则原子写入绝对路径。
Future<void> writeDataLocationBootstrap(
  Directory supportDirectory,
  Directory directory,
) async {
  await supportDirectory.create(recursive: true);
  final file = dataLocationBootstrapFile(supportDirectory);
  if (isDefaultDataDirectory(supportDirectory, directory)) {
    if (await file.exists()) await file.delete();
    return;
  }
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(
    jsonEncode({
      'schemaVersion': dataLocationSchemaVersion,
      'path': directory.absolute.path,
    }),
    flush: true,
  );
  await temporary.rename(file.path);
}
