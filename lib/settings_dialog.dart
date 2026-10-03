import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import 'storage.dart';
import 'appearance.dart';
import 'custom_fonts.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.store});
  final LocalStore store;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late String _theme;
  late String _palette;
  late String _font;
  Map<String, dynamic>? _custom;
  String? _error;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _theme = widget.store.theme;
    _palette = widget.store.palette;
    _font = widget.store.font;
    final custom = widget.store.settings['customFont'];
    if (custom is Map) _custom = Map<String, dynamic>.from(custom);
    _error = widget.store.fontError;
  }

  Future<void> _importFont() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: '字体',
            extensions: ['ttf', 'otf'],
            mimeTypes: [
              'font/ttf',
              'font/otf',
              'application/x-font-ttf',
              'application/vnd.ms-opentype',
              'application/octet-stream',
            ],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > maxFontBytes) {
        throw const FormatException('字体超过 64 MiB');
      }
      final custom = await importFont(
        widget.store,
        await file.readAsBytes(),
        file.name,
      );
      if (mounted) {
        setState(() {
          _custom = custom;
          _font = 'custom';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '导入字体失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _selectCustom() async {
    setState(() => _saving = true);
    await loadStoredFont(widget.store, selection: _custom!);
    if (mounted) {
      setState(() {
        _saving = false;
        _error = widget.store.fontError;
        if (_error == null) _font = 'custom';
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_font == 'custom') {
        await loadStoredFont(widget.store, selection: _custom!);
        final error = widget.store.fontError;
        if (error != null) {
          throw FormatException(error);
        }
      }
      await widget.store.setSettings(
        theme: _theme,
        palette: _palette,
        font: _font,
        extra: {if (_custom != null) 'customFont': _custom},
      );
      widget.store.fontError = null;
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Scaffold(
      appBar: AppBar(title: const Text('配色与字体')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '外观',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    key: const ValueKey('settings-theme'),
                    expandedInsets: EdgeInsets.zero,
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 6),
                      ),
                      minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
                      textStyle: WidgetStatePropertyAll(
                        Theme.of(context).textTheme.labelLarge
                            ?.copyWith(fontSize: 13),
                      ),
                    ),
                    segments: const [
                      ButtonSegment(value: 'system', label: Text('跟随系统')),
                      ButtonSegment(value: 'light', label: Text('浅色')),
                      ButtonSegment(value: 'dark', label: Text('深色')),
                    ],
                    selected: {_theme},
                    onSelectionChanged: _saving
                        ? null
                        : (values) => setState(() => _theme = values.single),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '配色',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: AppPalette.values
                        .map(
                          (palette) => ChoiceChip(
                            key: ValueKey('palette:${palette.name}'),
                            avatar: CircleAvatar(
                              backgroundColor: palette.primary(
                                Theme.of(context).brightness,
                              ),
                              radius: 6,
                            ),
                            label: Text(palette.label),
                            showCheckmark: false,
                            selectedColor: palette
                                .primary(Theme.of(context).brightness)
                                .withValues(alpha: .13),
                            selected: _palette == palette.name,
                            onSelected: _saving
                                ? null
                                : (_) =>
                                      setState(() => _palette = palette.name),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '字体',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        key: const ValueKey('font:system'),
                        label: const Text('系统字体'),
                        selected: _font == 'system',
                        onSelected: _saving
                            ? null
                            : (_) => setState(() => _font = 'system'),
                      ),
                      if (_custom != null)
                        ChoiceChip(
                          key: const ValueKey('font:custom'),
                          label: const Text('自定义字体'),
                          selected: _font == 'custom',
                          onSelected: _saving ? null : (_) => _selectCustom(),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _custom == null
                        ? '默认使用手机系统字体，可导入 TTF / OTF 字体文件。'
                        : '已导入：${_custom!['name']}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  TextButton.icon(
                    key: const ValueKey('import-font'),
                    onPressed: _saving ? null : _importFont,
                    icon: const Icon(Icons.file_open_outlined, size: 18),
                    label: Text(_saving ? '处理中…' : '导入字体'),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '预览：记下一个想法\nLittle Check · 你好，世界。',
                      style: TextStyle(
                        inherit: false,
                        color: Theme.of(context).colorScheme.onSurface,
                        fontFamily: _font == 'custom' && _custom != null
                            ? customFontFamily(_custom!['hash'] as String)
                            : ThemeData(platform: Theme.of(context).platform)
                                  .textTheme
                                  .bodyLarge
                                  ?.fontFamily,
                        fontSize: 18,
                        height: 1.6,
                      ),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _saving ? null : () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? '保存中…' : '保存'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
