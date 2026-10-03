import 'dart:convert';
import 'dart:io' as io;

import 'package:file/file.dart' show File;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class _Files implements FileSystem {
  _Files(this.path);
  final String path;
  @override
  Future<File> createFile(String name) async =>
      const LocalFileSystem().file('$path/$name');
}

void main() {
  test(
    'image cache survives manager restart and works after origin is offline',
    () async {
      final folder = await io.Directory.systemTemp.createTemp(
        'little-check-images-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final server = await io.HttpServer.bind(
        io.InternetAddress.loopbackIPv4,
        0,
      );
      var requests = 0;
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
      );
      server.listen((request) async {
        requests++;
        request.response.headers.set('cache-control', 'max-age=86400');
        request.response.add(bytes);
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/image.png';
      CacheManager manager() => CacheManager(
        Config(
          'test-image',
          repo: JsonCacheInfoRepository(path: '${folder.path}/metadata.json'),
          fileSystem: _Files(folder.path),
          stalePeriod: const Duration(days: 30),
          maxNrOfCacheObjects: 200,
        ),
      );
      final first = manager();
      expect(await (await first.getSingleFile(url)).readAsBytes(), bytes);
      await first.dispose();
      await server.close(force: true);
      final second = manager();
      try {
        expect(await (await second.getSingleFile(url)).readAsBytes(), bytes);
        expect(requests, 1);
        await second.emptyCache();
        expect(await second.getFileFromCache(url), isNull);
      } finally {
        await second.dispose();
      }
    },
  );
}
