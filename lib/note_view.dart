import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'app.dart';
import 'markdown_view.dart';
import 'storage.dart';
import 'selection_field.dart';
import 'tasks.dart';
import 'markdown_editing.dart';
import 'note_filename.dart';

class NotesView extends StatefulWidget {
  const NotesView({super.key, required this.store});
  final LocalStore store;
  @override
  State<NotesView> createState() => NotesViewState();
}

class NotesViewState extends State<NotesView> {
  List<Note> _notes = [];
  var _query = '';
  String? _folder;
  bool _trash = false;
  int _reloadVersion = 0;
  String? _error;
  final _scroll = ScrollController();

  void setQuery(String query) {
    if (_query != query && mounted) {
      setState(() => _query = query);
    }
  }

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    final version = ++_reloadVersion;
    try {
      // 先同步磁盘上的文件夹结构与笔记归属（外部 lck 等改动），再读正文。
      await widget.store.reloadNotebook();
      final notes = await widget.store.loadNotes(trash: _trash);
      if (mounted && version == _reloadVersion) {
        setState(() {
          _notes = notes;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && version == _reloadVersion) {
        setState(() => _error = '笔记读取失败，原文件已保留：$e');
      }
    }
  }

  Future<void> createNote() => _open(null);
  Future<void> _open(Note? note) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => NotePage(
          store: widget.store,
          note: note,
          folderId: _folder?.isNotEmpty == true ? _folder : null,
        ),
      ),
    );
    if (mounted) await reload();
  }

  Future<void> _import() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Markdown',
            extensions: ['md', 'markdown', 'txt'],
            mimeTypes: ['text/markdown', 'text/plain'],
            uniformTypeIdentifiers: ['public.plain-text'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 2 * 1024 * 1024) {
        throw const FormatException('笔记超过 2 MiB，暂不支持导入');
      }
      final note = await widget.store.saveNote(
        widget.store.newNoteId(),
        await file.readAsString(),
      );
      await reload();
      if (mounted) await _open(note);
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) await reload();
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<String?> _folderName(String title, [String initial = '']) async {
    final controller = TextEditingController(text: initial);
    try {
      return await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (context) {
          final theme = Theme.of(context);
          return StatefulBuilder(
            builder: (context, setSheetState) => Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 14,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.3,
                        ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: 80,
                    style: TextStyle(
                      fontSize: 15,
                      color: theme.colorScheme.onSurface,
                    ),
                    decoration: InputDecoration(
                      hintText: '输入文件夹名称',
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerLow,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 1.5,
                        ),
                      ),
                      suffixIcon: controller.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 18),
                              onPressed: () {
                                controller.clear();
                                setSheetState(() {});
                              },
                            )
                          : null,
                    ),
                    onChanged: (_) => setSheetState(() {}),
                    onSubmitted: (val) {
                      final trimmed = val.trim();
                      if (trimmed.isNotEmpty) {
                        Navigator.pop(context, trimmed);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: controller.text.trim().isEmpty
                            ? null
                            : () => Navigator.pop(
                                context,
                                controller.text.trim(),
                              ),
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    } finally {
      await WidgetsBinding.instance.endOfFrame;
      controller.dispose();
    }
  }

  Future<void> _manageFolder(String action) async {
    if (action == 'new') {
      final name = await _folderName('新建文件夹');
      if (name != null) {
        await _action(
          () => widget.store.putFolder(widget.store.newNoteId(), name),
        );
      }
    } else if (_folder != null && action == 'rename') {
      final name = await _folderName(
        '重命名文件夹',
        widget.store.folders[_folder] ?? '',
      );
      if (name != null) {
        await _action(() => widget.store.putFolder(_folder!, name));
      }
    } else if (_folder != null && action == 'delete') {
      final result = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除文件夹'),
          content: const Text('如何处理其中的笔记？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留到未分类'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('移入回收站'),
            ),
          ],
        ),
      );
      if (result != null) {
        await _action(() async {
          await widget.store.deleteFolder(_folder!, trashContents: result);
          _folder = null;
        });
      }
    }
  }

  Future<bool> _confirmDelete(String label) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(label),
          content: const Text('彻底删除后无法恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('彻底删除'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _noteActions(Note note) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_trash) ...[
              ListTile(
                leading: const Icon(Icons.restore_rounded),
                title: const Text('恢复笔记'),
                onTap: () => Navigator.pop(context, 'restore'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined),
                title: const Text('彻底删除'),
                onTap: () => Navigator.pop(context, 'destroy'),
              ),
            ] else ...[
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('移到未分类'),
                onTap: () => Navigator.pop(context, 'move:'),
              ),
              for (final folder in widget.store.folders.entries)
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text('移到 ${folder.value}'),
                  onTap: () => Navigator.pop(context, 'move:${folder.key}'),
                ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('移入回收站'),
                onTap: () => Navigator.pop(context, 'trash'),
              ),
            ],
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (choice == null) return;
    if (choice == 'destroy') {
      if (await _confirmDelete('彻底删除这篇笔记？')) {
        await _action(() => widget.store.deleteNotePermanently(note.id));
      }
    } else if (choice == 'restore' || choice == 'trash') {
      await _action(
        () => widget.store.trashNote(note.id, restore: choice == 'restore'),
      );
    } else if (choice.startsWith('move:')) {
      final id = choice.substring(5);
      await _action(
        () => widget.store.moveNote(note.id, id.isEmpty ? null : id),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notes = _notes
        .where(
          (note) =>
              (_folder == null ||
                  (_folder == ''
                      ? note.folderId == null
                      : note.folderId == _folder)) &&
              note.content.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: SelectionField(
                  compact: true,
                  label: '',
                  key: ValueKey('folders:$_trash:$_folder'),
                  value: _trash ? 'trash' : _folder ?? 'all',
                  options: {
                    'all': '全部笔记',
                    '': '未分类',
                    ...widget.store.folders,
                    'trash': '回收站',
                  },
                  onChanged: (value) async {
                    setState(() {
                      _trash = value == 'trash';
                      _folder = value == 'all' || _trash ? null : value;
                    });
                    await reload();
                  },
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '管理文件夹',
                onSelected: _manageFolder,
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'new', child: Text('新建文件夹')),
                  if (_folder?.isNotEmpty == true) ...[
                    const PopupMenuItem(value: 'rename', child: Text('重命名文件夹')),
                    const PopupMenuItem(value: 'delete', child: Text('删除文件夹')),
                  ],
                ],
              ),
              if (_trash)
                IconButton(
                  tooltip: '清空回收站',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: _notes.isEmpty
                      ? null
                      : () async {
                          if (await _confirmDelete('清空回收站？')) {
                            await _action(() async {
                              for (final note in _notes) {
                                await widget.store.deleteNotePermanently(
                                  note.id,
                                );
                              }
                            });
                          }
                        },
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_notes.length} 篇笔记 · 保存在本机',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.file_open_outlined, size: 17),
                label: const Text('导入'),
              ),
              TextButton.icon(
                onPressed: () async {
                  setState(() {
                    _trash = !_trash;
                    _folder = null;
                  });
                  await reload();
                },
                icon: Icon(
                  _trash ? Icons.notes_rounded : Icons.delete_outline_rounded,
                  size: 17,
                ),
                label: Text(_trash ? '返回笔记' : '回收站'),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: reload,
            child: ListView.separated(
              key: const PageStorageKey('notes-list'),
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: notes.isEmpty ? 1 : notes.length,
              separatorBuilder: (_, _) =>
                  const Divider(indent: 20, endIndent: 20),
              itemBuilder: (context, index) {
                if (notes.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
                    child: Column(
                      children: [
                        Icon(
                          Icons.edit_note_rounded,
                          size: 44,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _trash
                              ? '回收站为空'
                              : _query.isEmpty
                              ? '记下一个想法'
                              : '没有匹配的笔记',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _query.isEmpty ? '文字、清单和待办，都放在同一篇笔记里。' : '试试其他关键词。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.6,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (_query.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 20),
                            child: TextButton(
                              onPressed: createNote,
                              child: const Text('新建笔记'),
                            ),
                          ),
                      ],
                    ),
                  );
                }
                final note = notes[index];
                final tasks = MarkdownTasks.parse(note.content);
                final completed = tasks.where((task) => task.checked).length;
                return InkWell(
                  key: ValueKey(note.id),
                  onTap: () => _trash ? _noteActions(note) : _open(note),
                  onLongPress: () => _noteActions(note),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          margin: const EdgeInsets.only(right: 14),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(
                              alpha: .09,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            tasks.isEmpty
                                ? Icons.description_outlined
                                : Icons.checklist_rounded,
                            size: 21,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                note.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  height: 1.4,
                                ),
                              ),
                              if (note.excerpt.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 5),
                                  child: Text(
                                    note.excerpt,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      height: 1.5,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 9),
                              Wrap(
                                spacing: 12,
                                children: [
                                  Text(
                                    shortTime(note.updatedAt),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  if (tasks.isNotEmpty)
                                    Text(
                                      '$completed/${tasks.length} 已完成',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '笔记更多操作',
                          onPressed: () => _noteActions(note),
                          icon: const Icon(Icons.more_horiz_rounded, size: 20),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class NotePage extends StatefulWidget {
  const NotePage({super.key, required this.store, this.note, this.folderId});
  final LocalStore store;
  final Note? note;
  final String? folderId;
  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage> {
  late final TextEditingController _editor;
  late final String _id;
  late String _saved;
  late bool _editing;
  var _saving = false;
  var _allowExit = false;
  var _askingExit = false;
  String? _saveError;
  final _focus = FocusNode();
  bool get _dirty => _editor.text != _saved;

  @override
  void initState() {
    super.initState();
    _id = widget.note?.id ?? widget.store.newNoteId();
    widget.store.beginEditing(_id);
    _saved = widget.note?.content ?? '';
    _editor = TextEditingController(text: _saved)..addListener(_changed);
    _editing = widget.note == null;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.store.endEditing(_id);
    _editor.removeListener(_changed);
    _editor.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<bool> _save() async {
    if (_saving || !mounted) return false;
    final content = _editor.text;
    final previous = _saved;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.store.saveNote(_id, content);
      if (widget.note == null && widget.folderId != null) {
        await widget.store.moveNote(_id, widget.folderId);
      }
      // 字数统计在保存成功后再计入，避免失败时虚增。
      if (mounted) {
        final added = content.length - previous.length;
        if (added > 0) {
          DailyTrackerScope.of(context)?.recordNoteEdit(added: added);
        } else if (added < 0) {
          DailyTrackerScope.of(context)?.recordNoteEdit(deleted: -added);
        }
      }
      if (mounted) setState(() => _saved = content);
      return true;
    } catch (e) {
      if (mounted) setState(() => _saveError = '保存失败，编辑内容仍在：$e');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _close() async {
    if (_saving || _askingExit) return;
    _askingExit = true;
    try {
      if (_dirty) {
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('保存修改？'),
            content: const Text('这篇笔记有尚未保存的内容。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                child: const Text('继续编辑'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'leave'),
                child: const Text('不保存'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'save'),
                child: const Text('保存'),
              ),
            ],
          ),
        );
        if (choice == null || choice == 'cancel' || !mounted) return;
        if (choice == 'save' && !await _save()) return;
      }
      if (!mounted) return;
      setState(() => _allowExit = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    } finally {
      _askingExit = false;
    }
  }

  void _insert(MarkdownFormat format) {
    _editor.value = insertMarkdown(_editor.value, format);
    _focus.requestFocus();
  }

  Future<void> _moreFormats() async {
    _focus.unfocus();
    final format = await showModalBottomSheet<MarkdownFormat>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .65,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Markdown 格式'),
            ),
            Flexible(
              child: GridView.builder(
                key: const ValueKey('markdown-format-grid'),
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisExtent: 76,
                ),
                itemCount: MarkdownFormat.values.length,
                itemBuilder: (context, index) {
                  final item = MarkdownFormat.values[index];
                  return TextButton(
                    onPressed: () => Navigator.pop(context, item),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(_formatIcon(item)),
                        const SizedBox(height: 6),
                        Text(item.label, style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (format != null && mounted) _insert(format);
  }

  IconData _formatIcon(MarkdownFormat format) => switch (format) {
    MarkdownFormat.heading1 ||
    MarkdownFormat.heading2 ||
    MarkdownFormat.heading3 => Icons.title_rounded,
    MarkdownFormat.bold => Icons.format_bold_rounded,
    MarkdownFormat.italic => Icons.format_italic_rounded,
    MarkdownFormat.strike => Icons.strikethrough_s_rounded,
    MarkdownFormat.bullet => Icons.format_list_bulleted_rounded,
    MarkdownFormat.numbered => Icons.format_list_numbered_rounded,
    MarkdownFormat.task => Icons.check_box_outlined,
    MarkdownFormat.quote => Icons.format_quote_rounded,
    MarkdownFormat.link => Icons.link_rounded,
    MarkdownFormat.image => Icons.image_outlined,
    MarkdownFormat.code => Icons.code_rounded,
    MarkdownFormat.codeBlock => Icons.data_object_rounded,
    MarkdownFormat.divider => Icons.horizontal_rule_rounded,
    MarkdownFormat.table => Icons.table_chart_outlined,
  };

  Future<void> _export() async {
    try {
      if (!await _save() || !mounted) return;
      final filename = noteFilename(
        Note(id: _id, content: _editor.text, updatedAt: DateTime.now()).title,
      );
      if (Platform.isAndroid || Platform.isIOS) {
        await SharePlus.instance.share(
          ShareParams(
            files: [
              XFile(widget.store.noteFile(_id).path, mimeType: 'text/markdown'),
            ],
            subject: filename,
            fileNameOverrides: [filename],
          ),
        );
      } else {
        final location = await getSaveLocation(
          suggestedName: filename,
          acceptedTypeGroups: [
            const XTypeGroup(label: 'Markdown', extensions: ['md']),
          ],
        );
        if (location != null) {
          await XFile.fromData(
            await widget.store.noteFile(_id).readAsBytes(),
            mimeType: 'text/markdown',
            name: filename,
          ).saveTo(location.path);
        }
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = Note(
      id: _id,
      content: _editor.text,
      updatedAt: DateTime.now(),
    ).title;
    return PopScope(
      canPop: _allowExit || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '返回',
            onPressed: _close,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _editing ? '编辑笔记' : '笔记',
                style: const TextStyle(fontSize: 18),
              ),
              Text(
                _saving
                    ? '保存中…'
                    : _dirty
                    ? '有未保存修改'
                    : '已保存到本机',
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: _editing ? '预览' : '编辑',
              onPressed: _saving
                  ? null
                  : () {
                      _focus.unfocus();
                      setState(() => _editing = !_editing);
                    },
              icon: Icon(
                _editing ? Icons.visibility_outlined : Icons.edit_outlined,
              ),
            ),
            IconButton(
              tooltip: '导出 Markdown',
              onPressed: _saving ? null : _export,
              icon: const Icon(Icons.ios_share_rounded, size: 22),
            ),
            IconButton(
              tooltip: '保存笔记',
              onPressed: _saving
                  ? null
                  : () async {
                      if (await _save() && mounted) {
                        _focus.unfocus();
                        setState(() => _editing = false);
                      }
                    },
              icon: const Icon(Icons.check_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_saveError != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: theme.colorScheme.errorContainer,
                  child: Text(_saveError!),
                ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: _editing
                        ? Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: TextField(
                              key: const ValueKey('note-editor'),
                              controller: _editor,
                              focusNode: _focus,
                              enabled: !_saving,
                              autofocus: widget.note == null,
                              expands: true,
                              maxLines: null,
                              minLines: null,
                              textAlignVertical: TextAlignVertical.top,
                              keyboardType: TextInputType.multiline,
                              style: const TextStyle(fontSize: 16, height: 1.7),
                              decoration: const InputDecoration(
                                hintText: '# 标题\n\n写点什么…',
                                filled: false,
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(
                                  vertical: 20,
                                ),
                              ),
                            ),
                          )
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                            children: [
                              if (_editor.text.isEmpty)
                                Text(
                                  title,
                                  style: theme.textTheme.headlineSmall,
                                ),
                              MarkdownView(
                                content: _editor.text,
                                onToggle: _saving
                                    ? null
                                    : (offset) async {
                                        try {
                                          // toggle 前判断：由未勾选变为勾选才算完成一次。
                                          final wasUnchecked =
                                              _editor.text[offset] == ' ';
                                          _editor.text = MarkdownTasks.toggle(
                                            _editor.text,
                                            offset,
                                          );
                                          await _save();
                                          if (wasUnchecked && context.mounted) {
                                            DailyTrackerScope.of(context)
                                                ?.recordNoteEdit(tasks: 1);
                                          }
                                        } catch (e) {
                                          if (context.mounted) {
                                            showFailure(context, e);
                                          }
                                        }
                                      },
                              ),
                            ],
                          ),
                  ),
                ),
              ),
              if (_editing)
                Container(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: theme.dividerTheme.color!),
                    ),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: _saving
                              ? null
                              : () => _insert(MarkdownFormat.heading2),
                          child: const Text('标题'),
                        ),
                        IconButton(
                          tooltip: '加粗',
                          onPressed: _saving
                              ? null
                              : () => _insert(MarkdownFormat.bold),
                          icon: const Icon(Icons.format_bold_rounded),
                        ),
                        IconButton(
                          tooltip: '列表',
                          onPressed: _saving
                              ? null
                              : () => _insert(MarkdownFormat.bullet),
                          icon: const Icon(Icons.format_list_bulleted_rounded),
                        ),
                        IconButton(
                          tooltip: '待办',
                          onPressed: _saving
                              ? null
                              : () => _insert(MarkdownFormat.task),
                          icon: const Icon(Icons.check_box_outlined),
                        ),
                        IconButton(
                          tooltip: '链接',
                          onPressed: _saving
                              ? null
                              : () => _insert(MarkdownFormat.link),
                          icon: const Icon(Icons.link_rounded),
                        ),
                        IconButton(
                          tooltip: '代码',
                          onPressed: _saving
                              ? null
                              : () => _insert(MarkdownFormat.code),
                          icon: const Icon(Icons.code_rounded),
                        ),
                        IconButton(
                          tooltip: '更多格式',
                          onPressed: _saving ? null : _moreFormats,
                          icon: const Icon(Icons.add_circle_outline_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
