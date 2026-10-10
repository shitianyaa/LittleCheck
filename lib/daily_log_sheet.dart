import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'daily_tracker.dart';
import 'image_cache.dart';

Future<void> showDailyLogSheet(
  BuildContext context,
  DailyTracker tracker, {
  VoidCallback? onNoteSaved,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) =>
        _DailyLogSheetContent(tracker: tracker, onNoteSaved: onNoteSaved),
  );
}

class _DailyLogSheetContent extends StatefulWidget {
  const _DailyLogSheetContent({required this.tracker, this.onNoteSaved});
  final DailyTracker tracker;
  final VoidCallback? onNoteSaved;

  @override
  State<_DailyLogSheetContent> createState() => _DailyLogSheetContentState();
}

class _DailyLogSheetContentState extends State<_DailyLogSheetContent> {
  bool _saving = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    widget.tracker.addListener(_onTrackerChanged);
    unawaited(widget.tracker.ensureWallpaper());
  }

  @override
  void dispose() {
    widget.tracker.removeListener(_onTrackerChanged);
    super.dispose();
  }

  void _onTrackerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshWallpaper() async {
    setState(() => _refreshing = true);
    try {
      await widget.tracker.refreshWallpaper();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _handleSave() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final note = await widget.tracker.saveToFolder();
      if (!mounted) return;
      widget.onNoteSaved?.call();
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text('已归档至「每日回顾」：${note.title}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text('保存失败：$e'),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tracker = widget.tracker;
    final wallpaper = tracker.wallpaperUrl;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部壁纸与问候看板
          Container(
            height: 180,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(
                colors: [Color(0xFF283645), Color(0xFF1B232D)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .2),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (wallpaper != null)
                  CachedNetworkImage(
                    imageUrl: wallpaper,
                    cacheManager: imageFileCache,
                    fit: BoxFit.cover,
                    fadeInDuration: const Duration(milliseconds: 150),
                    placeholder: (context, url) => const SizedBox(),
                    errorWidget: (context, error, stackTrace) =>
                        const SizedBox(),
                  ),
                // 渐变蒙版保证文字清晰
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.black.withValues(alpha: .1),
                        Colors.black.withValues(alpha: .75),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
                Positioned(
                  top: 10,
                  right: 10,
                  child: IconButton(
                    tooltip: '刷新壁纸',
                    icon: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .45),
                        shape: BoxShape.circle,
                      ),
                      child: _refreshing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(
                              Icons.refresh_rounded,
                              size: 16,
                              color: Colors.white,
                            ),
                    ),
                    onPressed: _refreshing ? null : _refreshWallpaper,
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 14,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: .85,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          tracker.date,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        tracker.greeting,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      if (tracker.wallpaperTitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          tracker.wallpaperTitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (tracker.lastWallpaperError != null)
                  Positioned(
                    left: 10,
                    top: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .55),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 13,
                            color: Colors.white70,
                          ),
                          SizedBox(width: 5),
                          Text(
                            '壁纸源不可用，已回退必应',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 四大指标网格
          Row(
            children: [
              _metricTile(
                context,
                icon: Icons.touch_app_outlined,
                label: '应用活跃',
                value: '${tracker.opens} 次',
                detail: '日常启动与回顾',
              ),
              const SizedBox(width: 10),
              _metricTile(
                context,
                icon: Icons.rss_feed_rounded,
                label: '信息流探索',
                value: '${tracker.feedReads} 篇',
                detail: tracker.feedReads > 0
                    ? '最常看: ${tracker.topFeedSource}'
                    : '暂无动态',
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _metricTile(
                context,
                icon: Icons.auto_awesome_outlined,
                label: 'AI 辅助',
                value: '${tracker.aiTranslates + tracker.aiSummaries} 次',
                detail:
                    '${tracker.aiTranslates} 翻译 · ${tracker.aiSummaries} 总结',
              ),
              const SizedBox(width: 10),
              _metricTile(
                context,
                icon: Icons.edit_note_rounded,
                label: '笔记创作',
                value: '+${tracker.wordsAdded} 字',
                detail:
                    '-${tracker.wordsDeleted} 字 · ${tracker.tasksCompleted} 待办',
              ),
            ],
          ),
          const SizedBox(height: 20),
          // 底部操作按钮
          FilledButton.icon(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: _saving ? null : _handleSave,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    tracker.hasSavedToday
                        ? Icons.check_circle_outline
                        : Icons.auto_stories_rounded,
                    size: 20,
                  ),
            label: Text(
              tracker.hasSavedToday ? '今日已归档（点击更新手帐笔记）' : '保存为今日回顾笔记',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required String detail,
  }) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: .4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
