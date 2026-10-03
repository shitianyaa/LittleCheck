import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

// One manager for feed and note images; creating multiple managers with the
// same database key can corrupt cache metadata.
final imageFileCache = CacheManager(
  Config(
    'littleCheckImagesV1',
    stalePeriod: const Duration(days: 30),
    maxNrOfCacheObjects: 200,
  ),
);

Future<void> clearImageCache() async {
  await imageFileCache.emptyCache();
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
}
