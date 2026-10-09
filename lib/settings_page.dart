import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'ai.dart';
import 'app.dart';
import 'data_directory.dart';
import 'feed.dart';
import 'image_cache.dart';
import 'settings_dialog.dart';
import 'storage.dart';
import 'selection_field.dart';
import 'provider_page.dart';
import 'action_settings_page.dart';
import 'ai_keys.dart';
import 'sync_page.dart';

Future<Map<String, String>?> editFields(
  BuildContext context,
  String title,
  Map<String, String> values, {
  Set<String> secret = const {},
  Set<String> multiline = const {},
  Map<String, List<String>> choices = const {},
}) => Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => _FieldsPage(
      title: title,
      values: values,
      secret: secret,
      multiline: multiline,
      choices: choices,
    ),
  ),
);

class _FieldsPage extends StatefulWidget {
  const _FieldsPage({
    required this.title,
    required this.values,
    required this.secret,
    required this.multiline,
    required this.choices,
  });
  final String title;
  final Map<String, String> values;
  final Set<String> secret, multiline;
  final Map<String, List<String>> choices;
  @override
  State<_FieldsPage> createState() => _FieldsPageState();
}

class _FieldsPageState extends State<_FieldsPage> {
  late final fields = widget.values.map(
    (key, value) => MapEntry(key, TextEditingController(text: value)),
  );
  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            fields.map((key, value) => MapEntry(key, value.text)),
          ),
          child: const Text('确定'),
        ),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              for (final entry in fields.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: widget.choices.containsKey(entry.key)
                      ? SelectionField(
                          label: entry.key,
                          value:
                              widget.choices[entry.key]!.contains(
                                entry.value.text,
                              )
                              ? entry.value.text
                              : widget.choices[entry.key]!.first,
                          options: {
                            for (final v in widget.choices[entry.key]!)
                              v: v.isEmpty ? '不指定' : v,
                          },
                          onChanged: (v) =>
                              setState(() => entry.value.text = v),
                        )
                      : FieldLabel(
                          label: entry.key,
                          child: TextField(
                            controller: entry.value,
                            obscureText: widget.secret.contains(entry.key),
                            autocorrect: !widget.secret.contains(entry.key),
                            enableSuggestions: !widget.secret.contains(
                              entry.key,
                            ),
                            minLines: widget.multiline.contains(entry.key)
                                ? 2
                                : 1,
                            maxLines: widget.multiline.contains(entry.key)
                                ? 6
                                : 1,
                          ),
                        ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.store,
    required this.onAppearanceChanged,
  });
  final LocalStore store;
  final VoidCallback onAppearanceChanged;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _busy = false;
  LocalStore get store => widget.store;
  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await task();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _subscription([Map<String, dynamic>? source]) async {
    final values = await editFields(
      context,
      source == null ? '添加订阅源' : '编辑订阅源',
      {
        '名称': source?['name'] as String? ?? '',
        'JSON 地址': source?['url'] as String? ?? '',
      },
    );
    if (values == null) return;
    await _run(() async {
      if (values['名称']!.trim().isEmpty) throw const FormatException('订阅名称不能为空');
      final url = httpUri(values['JSON 地址']!.trim()).toString();
      final sources = store.subscriptions;
      if (sources.any((s) => s['url'] == url && s['id'] != source?['id'])) {
        throw const FormatException('已添加这个订阅地址');
      }
      final entry = {
        'id': source?['id'] ?? store.newNoteId(),
        'name': values['名称']!.trim(),
        'url': url,
        'enabled': source?['enabled'] ?? true,
      };
      sources.removeWhere((s) => s['id'] == entry['id']);
      sources.add(entry);
      await store.setSettings(extra: {'subscriptions': sources});
    });
  }

  Future<void> _provider([Map<String, dynamic>? provider]) async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ProviderPage(store: store, provider: provider),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _actions() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ActionSettingsPage(store: store)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _retention() async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: SelectionField(
          label: '信息流历史保留时间',
          value: '${store.feedRetentionDays}',
          options: const {
            '7': '最近 7 天',
            '14': '最近 14 天',
            '30': '最近 30 天',
            '90': '最近 90 天',
          },
          onChanged: (value) async {
            await _run(() async {
              await store.setSettings(
                extra: {'feedRetentionDays': int.parse(value)},
              );
              if (sheetContext.mounted) Navigator.pop(sheetContext);
            });
          },
        ),
      ),
    );
  }

  String _dataSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  Future<void> _openDataDirectory() async {
    if (!Platform.isWindows) return;
    await _run(() async {
      await Process.start('explorer.exe', [
        store.directory.path,
      ], mode: ProcessStartMode.detached);
    });
  }

  Future<void> _migrateDataDirectory() async {
    if (!Platform.isWindows) return;
    final selected = await getDirectoryPath(
      initialDirectory: store.directory.parent.path,
      confirmButtonText: '选择此文件夹',
      canCreateDirectories: true,
    );
    if (selected == null || !mounted) return;
    final target = Directory(selected).absolute;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('迁移数据目录？'),
            content: SingleChildScrollView(
              child: Text(
                '当前目录：\n${store.directory.path}\n\n'
                '目标目录：\n${target.path}\n\n'
                '请选择空文件夹。Little Check 会先复制并校验全部本地数据，校验成功后才切换启动位置；旧目录会保留为备份。\n\n'
                'AI Key、设备身份与配对密钥仍由 Windows 安全存储管理，不会复制到这个文件夹。云盘目录可用于备份，但不要让多台设备同时运行同一数据目录。\n\n'
                '迁移成功后应用会关闭，请重新打开。',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('迁移'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    await _run(() async {
      final manager = await DataDirectoryManager.system();
      final result = await manager.migrate(store, target);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('迁移完成'),
            content: Text(
              '已校验 ${result.files} 个文件，共 ${_dataSize(result.bytes)}。\n\n'
              '新目录：\n${result.target.path}\n\n'
              '当前旧目录仍保留为备份。Little Check 现在需要关闭，重新打开后会从新目录加载数据。',
            ),
            actions: [
              FilledButton(
                onPressed: () => exit(0),
                child: const Text('关闭 Little Check'),
              ),
            ],
          ),
        ),
      );
    });
  }

  Future<Map<String, dynamic>?> _pickModel(
    Map<String, dynamic> provider,
  ) async {
    final models = providerModels(provider);
    if (models.isEmpty) {
      showFailure(context, '请先添加模型');
      return null;
    }
    return models.length == 1
        ? models.single
        : await showModalBottomSheet<Map<String, dynamic>>(
            context: context,
            useSafeArea: true,
            showDragHandle: true,
            builder: (context) => ListView(
              shrinkWrap: true,
              children: [
                for (final m in models)
                  ListTile(
                    title: Text(modelLabel(m)),
                    onTap: () => Navigator.pop(context, m),
                  ),
              ],
            ),
          );
  }

  Future<void> _test(Map<String, dynamic> provider) async {
    final model = await _pickModel(provider);
    if (model == null || !mounted) return;
    await _run(() async {
      final client = AiClient();
      try {
        await client.chat(
          provider: {
            ...provider,
            'model': model['id'],
            'protocol': model['protocol'] ?? provider['protocol'] ?? 'chat',
          },
          key: await nextProviderKey(provider),
          messages: [
            {'role': 'user', 'content': '请仅回复 OK'},
          ],
          parameters: Map<String, dynamic>.from(
            model['parameters'] as Map? ?? {},
          ),
        );
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('模型连接成功')));
        }
      } finally {
        client.close();
      }
    });
  }

  Widget _section(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
    child: Text(
      label,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
        fontSize: 13,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              children: [
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                _section('订阅源'),
                for (final source in store.subscriptions)
                  ListTile(
                    leading: const Icon(Icons.rss_feed_rounded),
                    title: Text(source['name'] as String),
                    subtitle: Text(
                      source['url'] as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: _busy ? null : () => _subscription(source),
                    trailing: PopupMenuButton<String>(
                      enabled: !_busy,
                      onSelected: (action) => _run(() async {
                        final list = store.subscriptions;
                        if (action == '删除') {
                          list.removeWhere((s) => s['id'] == source['id']);
                        } else {
                          list.firstWhere(
                            (s) => s['id'] == source['id'],
                          )['enabled'] = source['enabled'] == false;
                        }
                        await store.setSettings(extra: {'subscriptions': list});
                      }),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: '切换',
                          child: Text(source['enabled'] == false ? '启用' : '停用'),
                        ),
                        const PopupMenuItem(value: '删除', child: Text('移除订阅')),
                      ],
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.add_rounded),
                  title: const Text('添加订阅源'),
                  onTap: _busy ? null : _subscription,
                ),
                ListTile(
                  leading: const Icon(Icons.history_rounded),
                  title: const Text('信息流历史'),
                  subtitle: Text('保留最近 ${store.feedRetentionDays} 天，刷新时合并新条目'),
                  onTap: _busy ? null : _retention,
                ),
                _section('AI 翻译 · 总结'),
                ListTile(
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: const Text('AI 功能'),
                  subtitle: const Text('主模型、翻译与识图模型，独立功能提示词'),
                  onTap: _busy ? null : _actions,
                ),
                _section('供应商'),
                for (final provider in providers(store))
                  ListTile(
                    leading: Icon(
                      store.settings['defaultProvider'] == provider['id']
                          ? Icons.check_circle_outline
                          : Icons.smart_toy_outlined,
                    ),
                    title: Text(provider['name'] as String),
                    subtitle: Text(
                      '${providerModels(provider).length} 个模型 · ${aiProtocols[provider['protocol'] ?? 'chat']}',
                    ),
                    onTap: _busy ? null : () => _provider(provider),
                    trailing: PopupMenuButton<String>(
                      enabled: !_busy,
                      onSelected: (action) async {
                        if (action == 'test') {
                          await _test(provider);
                          return;
                        }
                        final model = action == 'default'
                            ? await _pickModel(provider)
                            : null;
                        if (action == 'default' && model == null) return;
                        await _run(() async {
                          if (action == 'default') {
                            await store.setSettings(
                              extra: {
                                'defaultProvider': provider['id'],
                                'defaultModel': model!['id'],
                                'actionModels': {
                                  ...Map<String, dynamic>.from(
                                    store.settings['actionModels'] as Map? ??
                                        {},
                                  ),
                                  'main': {
                                    'providerId': provider['id'],
                                    'modelId': model['id'],
                                  },
                                },
                              },
                            );
                          } else {
                            final list = providers(store)
                              ..removeWhere((p) => p['id'] == provider['id']);
                            await store.setSettings(
                              extra: {
                                'aiProviders': list,
                                'defaultProvider':
                                    list.any(
                                      (p) =>
                                          p['id'] ==
                                          store.settings['defaultProvider'],
                                    )
                                    ? store.settings['defaultProvider']
                                    : list.firstOrNull?['id'],
                                'defaultModel':
                                    provider['id'] ==
                                        store.settings['defaultProvider']
                                    ? null
                                    : store.settings['defaultModel'],
                              },
                            );
                            final keys = await secureKeys.readAll();
                            final prefix = 'provider:${provider['id']}';
                            for (final name in keys.keys.where(
                              (k) => k == prefix || k.startsWith('$prefix:'),
                            )) {
                              await secureKeys.delete(key: name);
                            }
                          }
                        });
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'default', child: Text('设为主模型')),
                        PopupMenuItem(value: 'test', child: Text('测试连接')),
                        PopupMenuItem(value: 'remove', child: Text('删除供应商与密钥')),
                      ],
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.add_rounded),
                  title: const Text('添加 AI 供应商'),
                  subtitle: const Text(
                    'Chat / Responses / Messages · 密钥保存在系统安全存储',
                  ),
                  onTap: _busy ? null : _provider,
                ),
                _section('外观与存储'),
                ListTile(
                  leading: const Icon(Icons.devices_rounded),
                  title: const Text('设备同步'),
                  subtitle: const Text('Android 与 Windows · 局域网手动同步'),
                  onTap: _busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SyncPage(store: store),
                          ),
                        ),
                ),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('配色与字体'),
                  onTap: _busy
                      ? null
                      : () async {
                          final changed = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SettingsDialog(store: store),
                            ),
                          );
                          if (changed == true) {
                            widget.onAppearanceChanged();
                            if (mounted) setState(() {});
                          }
                        },
                ),
                if (defaultTargetPlatform == TargetPlatform.windows) ...[
                  ListTile(
                    leading: const Icon(Icons.folder_open_outlined),
                    title: const Text('数据存储位置'),
                    subtitle: Text(
                      store.directory.path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: _busy ? null : _openDataDirectory,
                  ),
                  ListTile(
                    leading: const Icon(Icons.drive_file_move_outline),
                    title: const Text('迁移数据目录'),
                    subtitle: const Text('选择空文件夹 · 复制校验后重启生效'),
                    onTap: _busy ? null : _migrateDataDirectory,
                  ),
                ],
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: const Text('清理图片缓存'),
                  subtitle: const Text('最多 200 张 · 30 天未使用自动清理'),
                  onTap: _busy
                      ? null
                      : () => _run(() async {
                          await clearImageCache();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('图片缓存已清理')),
                            );
                          }
                        }),
                ),
                _section('关于'),
                const ListTile(
                  title: Text('Little Check'),
                  subtitle: Text(
                    '信息流与本地 Markdown 笔记\n笔记可与配对设备同步，AI 密钥各端保存。卸载前请导出笔记。',
                  ),
                ),
                ListTile(
                  title: const Text('开源许可'),
                  leading: const Icon(Icons.info_outline_rounded),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'Little Check',
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
