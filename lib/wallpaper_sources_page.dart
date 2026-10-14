import 'package:flutter/material.dart';

import 'app.dart';
import 'daily_tracker.dart';

/// 每日手帐壁纸源管理：单源指定或随机轮换，支持增删改多个自定义 API。
class WallpaperSourcesPage extends StatefulWidget {
  const WallpaperSourcesPage({super.key});

  @override
  State<WallpaperSourcesPage> createState() => _WallpaperSourcesPageState();
}

class _WallpaperSourcesPageState extends State<WallpaperSourcesPage> {
  DailyTracker? _tracker;
  bool _busy = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tracker = DailyTrackerScope.of(context);
    if (tracker != _tracker) {
      _tracker?.removeListener(_onChanged);
      _tracker = tracker;
      _tracker?.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    _tracker?.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function(DailyTracker tracker) task) async {
    final tracker = _tracker;
    if (tracker == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await task(tracker);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is FormatException ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<String, String>?> _editSource({WallpaperSource? source}) async {
    final nameController = TextEditingController(text: source?.name ?? '');
    final urlController = TextEditingController(text: source?.url ?? '');
    try {
      return await showDialog<Map<String, String>>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(source == null ? '添加壁纸源' : '编辑壁纸源'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: '名称',
                    hintText: '例如 lolicon',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: urlController,
                  enabled: !_busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'API 地址',
                    hintText: 'https://api.lolicon.app/setu/v2',
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '支持返回图片直链，或返回包含图片地址的 JSON 接口。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, {
                'name': nameController.text,
                'url': urlController.text,
              }),
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      nameController.dispose();
      urlController.dispose();
    }
  }

  Future<void> _add() async {
    final values = await _editSource();
    if (values == null) return;
    await _run((t) => t.addWallpaperSource(values['name']!, values['url']!));
  }

  Future<void> _edit(WallpaperSource source) async {
    final values = await _editSource(source: source);
    if (values == null) return;
    await _run(
      (t) =>
          t.updateWallpaperSource(source.id, values['name']!, values['url']!),
    );
  }

  Future<void> _remove(WallpaperSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除壁纸源？'),
        content: Text('将移除「${source.name}」，不会删除已缓存的图片。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run((t) => t.removeWallpaperSource(source.id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tracker = _tracker;
    return Scaffold(
      appBar: AppBar(title: const Text('每日手帐壁纸源')),
      bottomNavigationBar: _busy
          ? const LinearProgressIndicator(minHeight: 2)
          : null,
      body: tracker == null
          ? const Center(child: Text('壁纸配置不可用'))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  children: [
                    _section('取图方式', subtitle: '指定单一来源，或在多个自定义源间随机换图'),
                    SegmentedButton<WallpaperMode>(
                      showSelectedIcon: false,
                      expandedInsets: EdgeInsets.zero,
                      segments: const [
                        ButtonSegment(
                          value: WallpaperMode.single,
                          label: Text('指定单一源'),
                          icon: Icon(Icons.push_pin_outlined, size: 18),
                        ),
                        ButtonSegment(
                          value: WallpaperMode.rotate,
                          label: Text('随机轮换'),
                          icon: Icon(Icons.shuffle_rounded, size: 18),
                        ),
                      ],
                      selected: {tracker.wallpaperMode},
                      onSelectionChanged: _busy
                          ? null
                          : (set) => _run((t) => t.setWallpaperMode(set.first)),
                    ),
                    _section('壁纸源', subtitle: '内置必应源固定置顶，可添加多个自定义 API'),
                    for (final source in tracker.wallpaperSources)
                      _sourceTile(theme, tracker, source),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _add,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('添加壁纸源'),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.errorContainer.withValues(
                              alpha: .3,
                            ),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: theme.colorScheme.error.withValues(
                                alpha: .5,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.error_outline_rounded,
                                size: 20,
                                color: theme.colorScheme.error,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      '自定义接口出错时会自动回退到必应风景。图片下载后缓存在本机，可在「清理图片缓存」中统一清理。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _sourceTile(
    ThemeData theme,
    DailyTracker tracker,
    WallpaperSource source,
  ) {
    final isActive =
        tracker.wallpaperMode == WallpaperMode.single &&
        tracker.activeWallpaperSourceId == source.id;
    final selectable = tracker.wallpaperMode == WallpaperMode.single;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive
              ? theme.colorScheme.primary.withValues(alpha: .5)
              : theme.colorScheme.outlineVariant.withValues(alpha: .4),
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Icon(
          source.builtin ? Icons.public_rounded : Icons.image_outlined,
          color: isActive
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(
          source.name,
          style: TextStyle(
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            color: isActive ? theme.colorScheme.primary : null,
          ),
        ),
        subtitle: Text(
          source.builtin ? '官方接口 · 每日自动更新' : source.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selectable)
              Icon(
                isActive
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 22,
                color: isActive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            if (!source.builtin)
              PopupMenuButton<String>(
                enabled: !_busy,
                onSelected: (action) {
                  if (action == 'edit') {
                    _edit(source);
                  } else if (action == 'delete') {
                    _remove(source);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
          ],
        ),
        onTap: selectable && !_busy
            ? () => _run((t) => t.setActiveWallpaperSource(source.id))
            : null,
      ),
    );
  }

  Widget _section(String title, {String? subtitle}) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ],
    ),
  );
}
