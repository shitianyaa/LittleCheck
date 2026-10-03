import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app.dart';
import 'feed.dart';
import 'markdown_view.dart';
import 'storage.dart';
import 'ai_actions.dart';
import 'ai_action_view.dart';
import 'ai_keys.dart';
import 'ai.dart';
import 'selection_field.dart';

class FeedView extends StatefulWidget {
  const FeedView({
    super.key,
    required this.store,
    required this.onNoteSaved,
    this.onNextSection,
  });
  final LocalStore store;
  final VoidCallback onNoteSaved;
  final VoidCallback? onNextSection;
  @override
  State<FeedView> createState() => FeedViewState();
}

class FeedViewState extends State<FeedView>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  FeedSnapshot? _snapshot;
  FeedSnapshot? _pending;
  String? _error;
  var _query = '';
  var _endpoint = '';
  var _refreshing = false;

  void setQuery(String query) {
    if (_query != query && mounted) {
      setState(() => _query = query);
    }
  }

  var _generation = 0;
  final _snapshots = <String, FeedSnapshot>{};
  final _badCaches = <String>{};
  String? _subscription;
  List<String> _labels = ['全部', '其他'];
  List<ScrollController> _scrolls = List.generate(2, (_) => ScrollController());
  late TabController _platforms;
  ScrollController get _scroll => _scrolls[_platforms.index];
  bool _showTop = false;
  String? _refreshMessage;
  Timer? _messageTimer;
  double _edgeDrag = 0;
  bool _backgrounded = false;

  void _updateTop() {
    final show =
        _scroll.hasClients &&
        _scroll.offset > _scroll.position.viewportDimension;
    if (show != _showTop && mounted) setState(() => _showTop = show);
  }

  void _toTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void initState() {
    super.initState();
    _platforms = TabController(length: _labels.length, vsync: this);
    _platforms.addListener(_updateTop);
    for (final scroll in _scrolls) {
      scroll.addListener(_updateTop);
    }
    WidgetsBinding.instance.addObserver(this);
    reloadEndpoint();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageTimer?.cancel();
    _platforms.dispose();
    for (final scroll in _scrolls) {
      scroll.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _backgrounded = true;
    if (state == AppLifecycleState.resumed && _backgrounded) {
      _backgrounded = false;
      refresh();
    }
  }

  List<Map<String, dynamic>> get _sources =>
      widget.store.subscriptions.where((s) => s['enabled'] != false).toList();

  void _accept(FeedSnapshot snapshot) {
    final names = snapshot.items.map((i) => i.platformName).toSet().toList()
      ..sort();
    names.remove('其他');
    final labels = ['全部', ...names, '其他'];
    if (labels.join('\u0000') != _labels.join('\u0000')) {
      final current = _labels[_platforms.index];
      final positions = {
        for (var i = 0; i < _labels.length; i++)
          _labels[i]: _scrolls[i].hasClients ? _scrolls[i].offset : 0.0,
      };
      final oldTabs = _platforms;
      final oldScrolls = _scrolls;
      _labels = labels;
      _platforms = TabController(
        length: labels.length,
        initialIndex: labels.contains(current) ? labels.indexOf(current) : 0,
        vsync: this,
      )..addListener(_updateTop);
      _scrolls = labels.map((label) {
        final scroll = ScrollController(
          initialScrollOffset: positions[label] ?? 0,
        )..addListener(_updateTop);
        return scroll;
      }).toList();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldTabs.dispose();
        for (final scroll in oldScrolls) {
          scroll.dispose();
        }
      });
    }
    _snapshot = snapshot;
  }

  Future<void> reloadEndpoint({bool fetch = true}) async {
    final generation = ++_generation;
    _snapshots.clear();
    _badCaches.clear();
    setState(() {
      _endpoint = _sources.isEmpty ? '' : 'subscriptions';
      _snapshot = null;
      _pending = null;
      _error = null;
      _subscription = null;
      _refreshing = false;
    });
    _messageTimer?.cancel();
    _refreshMessage = null;
    if (_sources.isEmpty) {
      if (widget.store.subscriptions.isNotEmpty) {
        setState(() => _accept(FeedSnapshot.merge({})));
        return;
      }
      final sample = await rootBundle.loadString('server/example-feed.json');
      if (mounted && generation == _generation) {
        setState(
          () => _accept(
            FeedSnapshot.fromJson(jsonDecode(sample) as Map<String, dynamic>),
          ),
        );
      }
      return;
    }
    final errors = <String>[];
    for (final source in _sources) {
      try {
        final cache = await widget.store.readCache(source['url'] as String);
        if (!mounted || generation != _generation) return;
        if (cache != null) {
          _snapshots[source['id'] as String] =
              FeedSnapshot.fromJson(
                Map<String, dynamic>.from(cache['snapshot'] as Map),
                history: true,
              ).retainHistory(
                null,
                now: DateTime.now(),
                days: widget.store.feedRetentionDays,
              );
        }
      } catch (_) {
        _badCaches.add(source['id'] as String);
        errors.add('${source['name']}：缓存损坏，正在重新获取');
      }
    }
    if (mounted && generation == _generation) {
      setState(() {
        _accept(FeedSnapshot.merge(_snapshots));
        _error = errors.isEmpty ? null : errors.join('\n');
      });
      if (fetch) await refresh();
    }
  }

  void pruneHistory() {
    for (final entry in _snapshots.entries.toList()) {
      _snapshots[entry.key] = entry.value.retainHistory(
        null,
        now: DateTime.now(),
        days: widget.store.feedRetentionDays,
      );
    }
    setState(() => _accept(FeedSnapshot.merge(_snapshots)));
  }

  Future<void> refresh() async {
    if (_refreshing || _sources.isEmpty) return;
    final generation = _generation;
    final sources = _sources
        .where((s) => _subscription == null || s['id'] == _subscription)
        .toList();
    setState(() {
      _refreshing = true;
      _error = null;
      _refreshMessage = null;
    });
    _messageTimer?.cancel();
    final updates = <String, FeedSnapshot>{};
    final errors = <String>[];
    // Bound network concurrency on small phones and large subscription lists.
    for (var offset = 0; offset < sources.length; offset += 3) {
      await Future.wait(
        sources.skip(offset).take(3).map((source) async {
          try {
            final snapshot = await FeedClient(widget.store).refresh(
              source['url'] as String,
              useCache: !_badCaches.contains(source['id']),
            );
            updates[source['id'] as String] = snapshot;
          } catch (e) {
            errors.add('${source['name']}：$e');
          }
        }),
      );
      if (!mounted || generation != _generation) return;
    }
    _snapshots.addAll(updates);
    _badCaches.removeAll(updates.keys);
    setState(() {
      _refreshing = false;
      _error = errors.isEmpty ? null : '更新失败，已有内容已保留。\n${errors.join('\n')}';
      final merged = FeedSnapshot.merge(_snapshots);
      if (_snapshot != null &&
          _scroll.hasClients &&
          _scroll.offset > 72 &&
          updates.isNotEmpty &&
          (merged.generatedAt != _snapshot!.generatedAt ||
              merged.items
                      .map((i) => '${i.id}\u0000${i.content}')
                      .join('\u0001') !=
                  _snapshot!.items
                      .map((i) => '${i.id}\u0000${i.content}')
                      .join('\u0001'))) {
        _pending = merged;
      } else {
        _accept(merged);
      }
      if (updates.isNotEmpty) {
        _refreshMessage = '内容更新于 ${shortTime(merged.generatedAt)}';
      }
    });
    _messageTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && generation == _generation) {
        setState(() => _refreshMessage = null);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        if (_sources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
            child: SelectionField(
              compact: true,
              label: '订阅来源',
              value: _subscription ?? '',
              options: {
                '': '全部订阅',
                for (final s in _sources)
                  s['id'] as String: s['name'] as String,
              },
              onChanged: _refreshing
                  ? null
                  : (value) {
                      setState(
                        () => _subscription = value.isEmpty ? null : value,
                      );
                      refresh();
                    },
            ),
          ),
        Row(
          children: [
            Expanded(
              child: TabBar(
                controller: _platforms,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerColor: Colors.transparent,
                indicatorSize: TabBarIndicatorSize.label,
                labelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
                labelColor: theme.colorScheme.primary,
                onTap: (_) => FocusManager.instance.primaryFocus?.unfocus(),
                tabs: [
                  const Tab(text: '全部'),
                  ..._labels.skip(1).map((name) => Tab(text: name)),
                ],
              ),
            ),
            IconButton(
              tooltip: '刷新信息流',
              onPressed: _refreshing || _endpoint.isEmpty ? null : refresh,
              icon: const Icon(Icons.refresh_rounded, size: 21),
            ),
          ],
        ),
        if (_endpoint.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.store.subscriptions.isEmpty
                    ? '示例信息流 · 在设置中连接你的内容'
                    : '所有订阅已停用 · 可在设置中启用',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        if (_refreshing) const LinearProgressIndicator(minHeight: 2),
        if (_pending != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                setState(() {
                  _accept(_pending!);
                  _pending = null;
                });
                for (final scroll in _scrolls) {
                  if (scroll.hasClients) scroll.jumpTo(0);
                }
              },
              child: const Text('有新内容 · 回顶部查看'),
            ),
          ),
        if (_error != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: .45),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _error!,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        Expanded(
          child: Stack(
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.metrics.axis != Axis.horizontal) {
                    return false;
                  }
                  if (notification is ScrollStartNotification) _edgeDrag = 0;
                  if (notification is OverscrollNotification &&
                      notification.dragDetails != null &&
                      _platforms.index == _labels.length - 1 &&
                      notification.overscroll > 0) {
                    _edgeDrag += notification.overscroll;
                    if (_edgeDrag > 72) {
                      _edgeDrag = -double.infinity;
                      widget.onNextSection?.call();
                    }
                  }
                  return false;
                },
                child: TabBarView(
                  key: const ValueKey('platform-pages'),
                  controller: _platforms,
                  physics: const ClampingScrollPhysics(),
                  children: List.generate(
                    _labels.length,
                    (index) => KeepAlivePage(child: _buildList(index)),
                  ),
                ),
              ),
              if (_refreshMessage != null)
                Positioned(
                  left: 16,
                  right: _showTop ? 72 : 16,
                  bottom: 16,
                  child: IgnorePointer(
                    child: Align(
                      alignment: Alignment.center,
                      child: Material(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(24),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 10,
                          ),
                          child: Text(
                            _refreshMessage!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_showTop)
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: FloatingActionButton.small(
                    heroTag: 'feed-top',
                    tooltip: '返回顶部',
                    onPressed: _toTop,
                    child: const Icon(Icons.arrow_upward_rounded),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildList(int platformIndex) {
    final theme = Theme.of(context);
    final platform = platformIndex == 0 ? null : _labels[platformIndex];
    final items =
        _snapshot?.items
            .where(
              (item) =>
                  (platform == null || item.platformName == platform) &&
                  (_subscription == null ||
                      item.subscriptionIds.contains(_subscription)) &&
                  '${item.title} ${item.summary} ${item.source} ${item.tags.join(' ')}'
                      .toLowerCase()
                      .contains(_query.toLowerCase()),
            )
            .toList() ??
        [];
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView.builder(
        key: PageStorageKey('feed-list-$platformIndex'),
        controller: _scrolls[platformIndex],
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 76),
        itemCount: items.isEmpty ? 1 : items.length,
        itemBuilder: (context, index) {
          if (items.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
              child: Column(
                children: [
                  Icon(
                    Icons.inbox_outlined,
                    size: 36,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _query.isNotEmpty
                        ? '没有匹配的内容'
                        : _refreshing
                        ? '正在获取内容…'
                        : platform == null
                        ? '这里还没有内容'
                        : '暂无$platform内容',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '下拉刷新，或在设置中检查信息流地址。',
                    style: TextStyle(fontSize: 13),
                  ),
                ],
              ),
            );
          }
          final item = items[index];
          final date = item.publishedAt.toLocal();
          final previous = index == 0
              ? null
              : items[index - 1].publishedAt.toLocal();
          final grouped =
              previous == null ||
              date.year != previous.year ||
              date.month != previous.month ||
              date.day != previous.day;
          return Column(
            key: ValueKey(item.id),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (grouped)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
                  child: Text(
                    '${date.month}月${date.day}日',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              InkWell(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => _FeedDetail(
                      item: item,
                      store: widget.store,
                      onNoteSaved: widget.onNoteSaved,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${item.platformName} · ${item.source}',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          Text(
                            shortTime(item.publishedAt),
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (postImages(item.content).isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Tooltip(
                                message: '包含图片',
                                child: Icon(
                                  Icons.image_outlined,
                                  size: 18,
                                  semanticLabel: '包含图片',
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item.title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        item.summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.55,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (item.tags.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 4,
                            children: item.tags
                                .map(
                                  (tag) => Text(
                                    '#$tag',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const Divider(indent: 20, endIndent: 20),
            ],
          );
        },
      ),
    );
  }
}

class _FeedDetail extends StatefulWidget {
  const _FeedDetail({
    required this.item,
    required this.store,
    required this.onNoteSaved,
  });
  final FeedItem item;
  final LocalStore store;
  final VoidCallback onNoteSaved;
  @override
  State<_FeedDetail> createState() => _FeedDetailState();
}

class _FeedDetailState extends State<_FeedDetail> {
  bool _saving = false,
      _saved = false,
      _showTranslation = false,
      _readmeBusy = false;
  String? _readmeError;
  Map<String, dynamic>? _readme;
  final _translation = GlobalKey<AiActionResultState>();
  final _summary = GlobalKey<AiActionResultState>();
  bool _showSummary = false;
  List<String> _translationImages = [], _summaryImages = [];
  AiActionService? _readmeService;

  @override
  void initState() {
    super.initState();
    _restoreReadme();
  }

  Future<void> _restoreReadme() async {
    final repo = githubRepository(widget.item);
    if (repo == null) return;
    try {
      final cached = await widget.store.readSupplement(repo);
      if (mounted && !_readmeBusy) setState(() => _readme = cached);
    } catch (e) {
      if (mounted) setState(() => _readmeError = aiFailureMessage(e));
    }
  }

  @override
  void dispose() {
    _readmeService?.close();
    super.dispose();
  }

  Future<void> _loadReadme() async {
    if (_readmeBusy) return;
    final service = AiActionService(widget.store);
    _readmeService = service;
    setState(() {
      _readmeBusy = true;
      _readmeError = null;
    });
    try {
      final value = await service.readme(widget.item, force: true);
      if (mounted) setState(() => _readme = value);
    } catch (e) {
      if (mounted) setState(() => _readmeError = aiFailureMessage(e));
    } finally {
      service.close();
      _readmeService = null;
      if (mounted) setState(() => _readmeBusy = false);
    }
  }

  Future<void> _action(AiAction action, {bool imageTranslation = false}) async {
    var images = <String>[];
    if ((action != AiAction.translate || imageTranslation) &&
        postImages(widget.item.content).isNotEmpty) {
      final picked = await chooseActionImages(context, widget.item, action);
      if (picked == null || !mounted) return;
      images = picked;
    }
    if (!mounted) return;
    setState(() {
      if (action == AiAction.translate) {
        _translationImages = images;
        _showTranslation = true;
      } else {
        _summaryImages = images;
        _showSummary = true;
      }
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final target = action == AiAction.translate ? _translation : _summary;
    if (target.currentContext != null) {
      await Scrollable.ensureVisible(
        target.currentContext!,
        duration: const Duration(milliseconds: 220),
      );
    }
    if (!mounted) return;
    await target.currentState?.run();
    await _restoreReadme();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读', style: TextStyle(fontSize: 18)),
        actions: [
          IconButton(
            tooltip: _saved ? '已保存为笔记' : '保存原帖为笔记',
            onPressed: _saving || _saved
                ? null
                : () async {
                    setState(() => _saving = true);
                    try {
                      final item = widget.item;
                      await widget.store.saveNote(
                        widget.store.newNoteId(),
                        '# ${item.title}\n\n${item.content}\n\n---\n来源：${item.source}${item.url == null ? '' : '\n${item.url}'}\n',
                      );
                      widget.onNoteSaved();
                      if (context.mounted) {
                        setState(() => _saved = true);
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('已保存到笔记')));
                      }
                    } catch (e) {
                      if (context.mounted) showFailure(context, e);
                    } finally {
                      if (mounted) setState(() => _saving = false);
                    }
                  },
            icon: Icon(
              _saved
                  ? Icons.bookmark_added_outlined
                  : Icons.bookmark_add_outlined,
            ),
          ),
        ],
      ),
      floatingActionButton: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton.icon(
              onPressed: () => _action(AiAction.summary),
              icon: const Icon(Icons.short_text_rounded, size: 20),
              label: const Text('总结'),
            ),
          ],
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 145),
            children: [
              Text(
                widget.item.title,
                style: const TextStyle(
                  fontSize: 24,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${widget.item.source} · ${shortTime(widget.item.publishedAt)}',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      if (_translation.currentState?.result != null) {
                        setState(() => _showTranslation = !_showTranslation);
                      } else {
                        _action(AiAction.translate);
                      }
                    },
                    icon: const Icon(Icons.translate_rounded, size: 17),
                    label: Text(
                      _translation.currentState?.result == null
                          ? '翻译'
                          : _showTranslation
                          ? '查看原文'
                          : '查看译文',
                    ),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  ),
                  if (postImages(widget.item.content).isNotEmpty)
                    TextButton.icon(
                      onPressed: () =>
                          _action(AiAction.translate, imageTranslation: true),
                      icon: const Icon(Icons.image_outlined, size: 17),
                      label: const Text('翻译图中文字'),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    ),
                  if (githubRepository(widget.item) != null)
                    TextButton.icon(
                      onPressed: _readmeBusy ? null : _loadReadme,
                      icon: _readmeBusy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            )
                          : const Icon(Icons.description_outlined, size: 17),
                      label: Text(_readme == null ? '拉取 README' : '更新 README'),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Offstage(
                offstage: !_showTranslation,
                child: AiActionResult(
                  key: _translation,
                  item: widget.item,
                  store: widget.store,
                  action: AiAction.translate,
                  images: _translationImages,
                  onNoteSaved: widget.onNoteSaved,
                  onChanged: (_) {
                    if (mounted) setState(() => _showTranslation = true);
                  },
                ),
              ),
              if (!_showTranslation) MarkdownView(content: widget.item.content),
              if (_readmeError != null)
                Text(
                  _readmeError!,
                  style: TextStyle(color: scheme.error, fontSize: 13),
                ),
              if (_readme != null)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('README'),
                    subtitle: const Text('已缓存，AI 操作会带入这份资料'),
                    children: [
                      if ((_readme!['notice'] as String).isNotEmpty)
                        Text(_readme!['notice'] as String),
                      MarkdownView(content: _readme!['text'] as String),
                    ],
                  ),
                ),
              if (widget.item.url != null)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        try {
                          if (!await launchUrl(
                            widget.item.url!,
                            mode: LaunchMode.externalApplication,
                          )) {
                            throw const FormatException('无法打开来源链接');
                          }
                        } catch (e) {
                          if (context.mounted) showFailure(context, e);
                        }
                      },
                      icon: const Icon(Icons.open_in_new_rounded, size: 17),
                      label: const Text('打开来源'),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              Offstage(
                offstage: !_showSummary,
                child: AiActionResult(
                  key: _summary,
                  item: widget.item,
                  store: widget.store,
                  action: AiAction.summary,
                  images: _summaryImages,
                  onNoteSaved: widget.onNoteSaved,
                  onChanged: (_) {
                    if (mounted) setState(() => _showSummary = true);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
