import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ai.dart';
import 'ai_actions.dart';
import 'ai_keys.dart';
import 'image_cache.dart';
import 'markdown_view.dart';
import 'storage.dart';
import 'feed.dart';

Future<List<String>?> chooseActionImages(
  BuildContext context,
  FeedItem item,
  AiAction action,
) {
  final images = postImages(item.content);
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _ImagePicker(images: images, action: action),
  );
}

class _ImagePicker extends StatefulWidget {
  const _ImagePicker({required this.images, required this.action});
  final List<String> images;
  final AiAction action;
  @override
  State<_ImagePicker> createState() => _ImagePickerState();
}

class _ImagePickerState extends State<_ImagePicker> {
  late final _selected = <String>{
    if (widget.images.isNotEmpty) widget.images.first,
  };
  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .62,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '选择附加图片 · ${_selected.length}/3',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(
                onPressed:
                    _selected.isEmpty && widget.action == AiAction.translate
                    ? null
                    : () => Navigator.pop(
                        context,
                        widget.images.where(_selected.contains).toList(),
                      ),
                child: Text('开始${widget.action.label}'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: widget.images.length,
            itemBuilder: (_, index) => ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: widget.images[index],
                  cacheManager: imageFileCache,
                  width: 52,
                  height: 52,
                  fit: BoxFit.cover,
                  memCacheWidth: 128,
                  errorWidget: (_, _, _) =>
                      const Icon(Icons.broken_image_outlined),
                ),
              ),
              title: Text('图片 ${index + 1}'),
              trailing: Icon(
                _selected.contains(widget.images[index])
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: _selected.contains(widget.images[index])
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              onTap: () {
                final url = widget.images[index];
                if (!_selected.contains(url) && _selected.length >= 3) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('单次最多选择三张图片')));
                  return;
                }
                setState(
                  () => _selected.contains(url)
                      ? _selected.remove(url)
                      : _selected.add(url),
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            widget.action == AiAction.translate
                ? '实际发送选中的图片，翻译其中可见文字。'
                : '可取消选择，只处理文字；不会声称看过未附加的图片。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );
}

class AiActionResult extends StatefulWidget {
  const AiActionResult({
    super.key,
    required this.item,
    required this.store,
    required this.action,
    required this.onNoteSaved,
    this.images = const [],
    this.onChanged,
  });
  final FeedItem item;
  final LocalStore store;
  final AiAction action;
  final List<String> images;
  final VoidCallback onNoteSaved;
  final ValueChanged<Map<String, dynamic>>? onChanged;
  @override
  State<AiActionResult> createState() => AiActionResultState();
}

class AiActionResultState extends State<AiActionResult> {
  Map<String, dynamic>? result;
  String? _error;
  bool _busy = false, _saving = false;
  String? _savedId;
  int _generation = 0;
  AiActionService? _service;
  final _clock = Stopwatch();
  Timer? _clockTimer;
  bool _paused = false;
  late List<String> _images = widget.images;

  @override
  void didUpdateWidget(covariant AiActionResult oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.images, widget.images)) _images = widget.images;
  }

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final generation = _generation;
    final service = AiActionService(widget.store);
    try {
      final images = widget.images.isEmpty
          ? await service.previousImages(widget.item, widget.action)
          : widget.images;
      final previous = await service.previousResult(widget.item, widget.action);
      final cached =
          previous ?? await service.cached(widget.item, widget.action, images);
      if (mounted && generation == _generation && !_busy && cached != null) {
        if (previous == null && cached['cacheId'] is String) {
          await widget.store.saveActionImages(
            service.selectionIdentity(widget.item, widget.action),
            images,
            cacheId: cached['cacheId'] as String,
          );
          if (!mounted || generation != _generation || _busy) return;
        }
        setState(() {
          _images = images;
          result = cached;
        });
        widget.onChanged?.call(cached);
      }
    } catch (e) {
      if (mounted && aiFailureMessage(e).contains('缓存')) {
        setState(() => _error = aiFailureMessage(e));
      }
    } finally {
      service.close();
    }
  }

  @override
  void dispose() {
    _generation++;
    _clockTimer?.cancel();
    _clock.stop();
    _service?.close();
    super.dispose();
  }

  Future<bool> run({bool force = false}) async {
    if (_busy) return false;
    final generation = ++_generation;
    final service = AiActionService(widget.store);
    _service = service;
    _clock
      ..reset()
      ..start();
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _busy) setState(() {});
    });
    setState(() {
      _busy = true;
      _paused = false;
      _error = null;
    });
    var succeeded = false;
    try {
      final next = await service.run(
        widget.item,
        widget.action,
        images: _images,
        force: force,
      );
      if (!mounted || generation != _generation) return false;
      setState(() {
        result = next;
        _savedId = null;
      });
      widget.onChanged?.call(next);
      succeeded = true;
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = aiFailureMessage(e));
      }
    } finally {
      service.close();
      if (_service == service) _service = null;
      if (mounted && generation == _generation) {
        _clockTimer?.cancel();
        _clock.stop();
        setState(() => _busy = false);
      }
    }
    return succeeded;
  }

  Future<void> _saveNote() async {
    if (result == null || _saving || _savedId != null) return;
    setState(() => _saving = true);
    try {
      final note = await widget.store.saveAiNote(
        widget.action.name,
        '${widget.item.title} · ${widget.action.label}',
        '${result!['text']}\n\n---\n动作：${widget.action.label}\n模型：${result!['model']}\n原帖：${widget.item.url ?? widget.item.source}\n',
      );
      widget.onNoteSaved();
      if (mounted) {
        setState(() => _savedId = note.id);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已存入「${widget.action.folder}」')));
      }
    } catch (e) {
      if (mounted) setState(() => _error = aiFailureMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (result != null) ...[
          Padding(
            padding: EdgeInsets.zero,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.action == AiAction.translate ? 'AI 译文' : 'AI 总结',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: '复制${widget.action.label}结果',
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: result!['text'] as String),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('已复制')));
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                ),
                IconButton(
                  tooltip: '重新${widget.action.label}',
                  onPressed: _busy ? null : () => run(force: true),
                  icon: const Icon(Icons.refresh_rounded, size: 19),
                ),
                IconButton(
                  tooltip: _savedId == null ? '存为笔记' : '已存为笔记',
                  onPressed: _saving || _savedId != null ? null : _saveNote,
                  icon: Icon(
                    _savedId == null
                        ? Icons.note_add_outlined
                        : Icons.check_rounded,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
          if (result!['previousVersion'] == true)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('已保留上次结果。原帖或配置有变化，可点击重新生成。'),
            ),
          if ((result!['notice'] as String).isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 0, vertical: 6),
              child: Text(
                result!['notice'] as String,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
        if (_busy)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '正在${widget.action.label} · 用时 ${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒',
                  ),
                ),
                IconButton(
                  tooltip: '暂停${widget.action.label}',
                  onPressed: () {
                    _generation++;
                    _service?.close();
                    _clockTimer?.cancel();
                    _clock.stop();
                    setState(() {
                      _busy = false;
                      _paused = true;
                      _error = null;
                    });
                  },
                  icon: const Icon(Icons.pause_rounded),
                ),
              ],
            ),
          ),
        if (_paused)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  '已暂停 · 用时 ${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒',
                ),
                TextButton.icon(
                  onPressed: () => run(force: true),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('重新开始'),
                ),
                const Text('继续需重新请求，已有结果保留。'),
              ],
            ),
          ),
        if (!_busy && !_paused && result?['durationMs'] is num)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '总用时 ${(result!['durationMs'] / 1000).toStringAsFixed(1)} 秒',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_error != null)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 0, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _error!,
                  style: TextStyle(color: scheme.error, fontSize: 13),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : () => run(force: true),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        if (result != null) MarkdownView(content: result!['text'] as String),
      ],
    );
    return content;
  }
}
