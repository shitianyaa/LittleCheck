import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'markdown_view.dart';
import 'note_view.dart';
import 'storage.dart';

const documentChannel = MethodChannel('little_check/documents');

class ExternalDocuments {
  ExternalDocuments({
    required this.navigator,
    required this.store,
    required this.onSaved,
    bool? enabled,
  }) : enabled = enabled ?? Platform.isAndroid;
  final GlobalKey<NavigatorState> navigator;
  final LocalStore store;
  final VoidCallback onSaved;
  final bool enabled;
  Future<void> _queue = Future.value();
  bool _disposed = false;
  void start() {
    if (!enabled) return;
    documentChannel.setMethodCallHandler((call) async {
      if (call.method == 'available') _drain();
    });
    _drain();
  }

  void dispose() {
    _disposed = true;
    if (enabled) documentChannel.setMethodCallHandler(null);
  }

  void _drain() {
    _queue = _queue
        .then((_) async {
          if (_disposed) return;
          final data =
              await documentChannel.invokeListMethod<dynamic>('drain') ?? [];
          for (final value in data) {
            if (_disposed) return;
            final entry = Map<String, dynamic>.from(value as Map);
            final context = navigator.currentContext;
            if (context == null || !context.mounted) return;
            if (entry['error'] != null) {
              showFailure(context, entry['error']);
              continue;
            }
            await navigator.currentState!.push<void>(
              MaterialPageRoute(
                builder: (_) => _DocumentPreview(
                  store: store,
                  name: entry['name'] as String,
                  content: entry['content'] as String,
                  onSaved: onSaved,
                ),
              ),
            );
          }
        })
        .catchError((Object e) {
          final context = navigator.currentContext;
          if (!_disposed && context != null && context.mounted) {
            showFailure(context, '打开文档失败：$e');
          }
        });
  }
}

class _DocumentPreview extends StatefulWidget {
  const _DocumentPreview({
    required this.store,
    required this.name,
    required this.content,
    required this.onSaved,
  });
  final LocalStore store;
  final String name, content;
  final VoidCallback onSaved;
  @override
  State<_DocumentPreview> createState() => _DocumentPreviewState();
}

class _DocumentPreviewState extends State<_DocumentPreview> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.name, overflow: TextOverflow.ellipsis)),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Expanded(child: Text('外部文档预览 · 原文件保持不变')),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          try {
                            final note = await widget.store.saveNote(
                              widget.store.newNoteId(),
                              widget.content,
                            );
                            widget.onSaved();
                            if (context.mounted) {
                              await Navigator.pushReplacement<void, void>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      NotePage(store: widget.store, note: note),
                                ),
                              );
                            }
                            widget.onSaved();
                          } catch (e) {
                            if (context.mounted) showFailure(context, e);
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        },
                  child: const Text('导入笔记'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [MarkdownView(content: widget.content)],
            ),
          ),
        ],
      ),
    ),
  );
}
