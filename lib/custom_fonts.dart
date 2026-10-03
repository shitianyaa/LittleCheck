import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'storage.dart';

const maxFontBytes = 64 * 1024 * 1024;
final _loaded = <String>{};

void validateFont(Uint8List bytes) {
  if (bytes.length < 12 || bytes.length > maxFontBytes) {
    throw const FormatException('字体文件无效或超过 64 MiB');
  }
  final data = ByteData.sublistView(bytes);
  final signature = data.getUint32(0);
  if (signature != 0x00010000 && signature != 0x4f54544f) {
    throw const FormatException('请选择有效的 TTF 或 OTF 字体，不支持字体合集 TTC');
  }
  final count = data.getUint16(4);
  if (count == 0 || count > 4096 || 12 + count * 16 > bytes.length) {
    throw const FormatException('字体目录损坏');
  }
  final tables = <String>{};
  for (var index = 0; index < count; index++) {
    final start = 12 + index * 16;
    final tag = String.fromCharCodes(bytes.sublist(start, start + 4));
    final offset = data.getUint32(start + 8),
        length = data.getUint32(start + 12);
    if (offset > bytes.length ||
        length > bytes.length - offset ||
        !tables.add(tag)) {
      throw const FormatException('字体数据损坏');
    }
  }
  if (!tables.containsAll(['cmap', 'head', 'maxp', 'name'])) {
    throw const FormatException('字体缺少必要的 OpenType 数据');
  }
}

String customFontFamily(String hash) => 'LittleCheckFont_$hash';

File customFontFile(LocalStore store, String hash) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
    throw const FormatException('无效的字体标识');
  }
  return File('${store.directory.path}/fonts/$hash.font');
}

Future<void> _load(Uint8List bytes, String hash) async {
  if (_loaded.contains(hash)) return;
  final loader = FontLoader(customFontFamily(hash))
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
  _loaded.add(hash);
}

Future<Map<String, String>> importFont(
  LocalStore store,
  Uint8List bytes,
  String filename,
) async {
  validateFont(bytes);
  final hash = sha256.convert(bytes).toString();
  await _load(bytes, hash);
  final file = customFontFile(store, hash);
  await file.parent.create(recursive: true);
  // Reimporting the same font also repairs a damaged local copy.
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsBytes(bytes, flush: true);
  await temporary.rename(file.path);
  return {'hash': hash, 'name': filename.split(RegExp(r'[/\\]')).last};
}

Future<void> loadStoredFont(
  LocalStore store, {
  Map<String, dynamic>? selection,
}) async {
  store.fontError = null;
  if (selection == null && store.settings['font'] != 'custom') return;
  try {
    final hash =
        (selection ?? store.settings['customFont'] as Map)['hash'] as String;
    final file = customFontFile(store, hash);
    if (await file.length() > maxFontBytes) {
      throw const FormatException('字体超过 64 MiB');
    }
    final bytes = await file.readAsBytes();
    validateFont(bytes);
    if (sha256.convert(bytes).toString() != hash) {
      throw const FormatException('字体文件内容已损坏');
    }
    await _load(bytes, hash);
  } catch (_) {
    store.fontError = '自定义字体无法加载，已临时使用系统字体。请在配色与字体中重新导入。';
  }
}
