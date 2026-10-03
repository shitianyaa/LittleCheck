import 'dart:convert';

import 'package:flutter/material.dart';

import 'ai.dart';
import 'ai_keys.dart';
import 'model_presets.dart';
import 'selection_field.dart';
import 'storage.dart';

class ProviderPage extends StatefulWidget {
  const ProviderPage({super.key, required this.store, this.provider});
  final LocalStore store;
  final Map<String, dynamic>? provider;
  @override
  State<ProviderPage> createState() => _ProviderPageState();
}

class _ProviderPageState extends State<ProviderPage> {
  late final _name = TextEditingController(
    text: widget.provider?['name'] as String? ?? '',
  );
  late final _base = TextEditingController(
    text: widget.provider?['baseUrl'] as String? ?? '',
  );
  final _keys = <Map<String, dynamic>>[];
  final _removedKeyControllers = <TextEditingController>[];
  bool _loadingKeys = true, _keysFailed = false;
  late final _id =
      widget.provider?['id'] as String? ?? widget.store.newNoteId();
  late String _protocol = widget.provider?['protocol'] as String? ?? 'chat';
  late final List<Map<String, dynamic>> _models = widget.provider == null
      ? []
      : providerModels(widget.provider!);
  var _busy = false;
  String? _error;
  AiClient? _client;

  Map<String, dynamic> get _draft => {
    'id': _id,
    'name': _name.text.trim(),
    'baseUrl': _base.text.trim(),
    'protocol': _protocol,
    'models': _models,
  };
  @override
  void dispose() {
    _client?.close();
    for (final c in [
      _name,
      _base,
      ..._keys.map((k) => k['controller'] as TextEditingController),
      ..._removedKeyControllers,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    try {
      final entries = providerKeys(widget.provider ?? {});
      if (entries.isEmpty && widget.provider?['keys'] == null) {
        final old = await secureKeys.read(key: 'provider:$_id') ?? '';
        entries.add({
          'id': 'legacy',
          'name': 'Key 1',
          'enabled': true,
          'legacy': true,
          'value': old,
        });
      }
      final drafts = <Map<String, dynamic>>[];
      for (final entry in entries) {
        final value =
            entry['value'] as String? ??
            await secureKeys.read(
              key: providerKeyName(_id, entry['id'] as String),
            ) ??
            '';
        drafts.add({
          ...entry,
          'original': value,
          'controller': TextEditingController(text: value),
          'visible': true,
          'stored': entry['legacy'] != true || value.isNotEmpty,
        });
      }
      if (!mounted) {
        for (final k in drafts) {
          (k['controller'] as TextEditingController).dispose();
        }
        return;
      }
      setState(() {
        _keys.addAll(drafts);
        _loadingKeys = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _keysFailed = true;
          _loadingKeys = false;
          _error = '无法读取已保存密钥，请返回后重试；原配置已保留';
        });
      }
    }
  }

  Future<void> _editModel([Map<String, dynamic>? model]) async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => ModelPage(
          model: model,
          protocol: _protocol,
          existingIds: _models
              .where((m) => m['id'] != model?['id'])
              .map((m) => m['id'] as String)
              .toSet(),
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (_models.any(
      (m) => m['id'] == result['id'] && m['id'] != model?['id'],
    )) {
      setState(() => _error = '这个模型 ID 已存在，请编辑已有模型');
      return;
    }
    setState(() {
      _models.removeWhere((m) => m['id'] == model?['id']);
      _models.add(result);
      _error = null;
    });
  }

  Future<void> _fetch() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = AiClient();
    _client = client;
    try {
      aiEndpoint(_base.text.trim(), _protocol, true);
      final key =
          _keys
              .where((k) => k['enabled'] != false)
              .map(
                (k) => (k['controller'] as TextEditingController).text.trim(),
              )
              .where((v) => v.isNotEmpty)
              .firstOrNull ??
          '';
      final fetched = await client.fetchModels(_draft, key);
      if (!mounted) return;
      final selected = await showModalBottomSheet<List<Map<String, dynamic>>>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => _ModelPicker(
          models: fetched,
          existing: _models.map((m) => m['id'] as String).toSet(),
        ),
      );
      if (selected != null && mounted) {
        setState(() {
          for (final m in selected) {
            if (!_models.any((old) => old['id'] == m['id'])) _models.add(m);
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '拉取失败：$e。已填写的配置保留，可手动添加模型。');
    } finally {
      client.close();
      _client = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final staged = <String>[];
    var committed = false;
    try {
      if (_name.text.trim().isEmpty) throw const FormatException('请填写供应商名称');
      aiEndpoint(_base.text.trim(), _protocol);
      final metadata = <Map<String, dynamic>>[];
      final unique = <String>{};
      for (final entry in _keys) {
        final value = (entry['controller'] as TextEditingController).text
            .trim();
        if (value.isEmpty) {
          if ((entry['original'] as String? ?? '').isNotEmpty ||
              entry['stored'] == true) {
            throw const FormatException('已有 Key 不能为空；请使用移除按钮');
          }
          continue;
        }
        if (value.contains(RegExp(r'[\r\n]'))) {
          throw const FormatException('单个 Key 不能包含换行');
        }
        if (!unique.add(value)) throw const FormatException('存在重复 Key，请保留一份');
        final changed = value != entry['original'] || entry['legacy'] == true;
        final id = changed ? widget.store.newNoteId() : entry['id'] as String;
        if (changed) {
          final storageName = providerKeyName(_id, id);
          staged.add(storageName);
          await secureKeys.write(key: storageName, value: value);
        }
        metadata.add({
          'id': id,
          'name': entry['name'],
          'enabled': entry['enabled'] != false,
        });
      }
      final list = providers(widget.store)..removeWhere((p) => p['id'] == _id);
      list.add({..._draft, 'keys': metadata});
      await widget.store.setSettings(
        extra: {
          'aiProviders': list,
          'defaultProvider': widget.store.settings['defaultProvider'] ?? _id,
        },
      );
      committed = true;
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (!committed) {
        for (final key in staged) {
          try {
            await secureKeys.delete(key: key);
          } catch (_) {
            if (mounted) setState(() => _error = '配置未保存，临时密钥清理失败，请重试保存');
          }
        }
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.provider == null ? '添加供应商' : '编辑供应商'),
        actions: [
          TextButton(
            onPressed: _busy || _loadingKeys || _keysFailed ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      bottomNavigationBar: _status(context, _error, _busy),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              FieldLabel(
                label: '供应商名称',
                child: TextField(controller: _name, enabled: !_busy),
              ),
              const SizedBox(height: 20),
              SelectionField(
                label: '默认调用协议',
                value: _protocol,
                options: aiProtocols,
                onChanged: _busy ? null : (v) => setState(() => _protocol = v),
              ),
              const SizedBox(height: 20),
              FieldLabel(
                label: '服务地址',
                child: TextField(
                  controller: _base,
                  enabled: !_busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _protocol == 'messages'
                      ? 'Messages 常见地址以 / 结尾；部分服务使用 /v1/。仅作提醒，请按供应商说明填写，HTTP / HTTPS 均可。'
                      : 'Chat / Responses 常见地址带 /v1。仅作提醒，不自动添加；请按供应商说明填写，HTTP / HTTPS 均可。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Row(
                children: [
                  Text(
                    'API Keys',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _busy || _loadingKeys
                        ? null
                        : () => setState(
                            () => _keys.add({
                              'id': widget.store.newNoteId(),
                              'name': 'Key ${_keys.length + 1}',
                              'enabled': true,
                              'visible': true,
                              'original': '',
                              'controller': TextEditingController(),
                            }),
                          ),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('添加'),
                  ),
                ],
              ),
              if (_loadingKeys) const LinearProgressIndicator(minHeight: 2),
              for (final key in _keys) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        key: ValueKey('key-name:${key['id']}'),
                        initialValue: key['name'] as String,
                        style: Theme.of(context).textTheme.labelMedium,
                        decoration: const InputDecoration(
                          isDense: true,
                          filled: false,
                          border: InputBorder.none,
                        ),
                        onChanged: (value) => key['name'] = value.trim().isEmpty
                            ? 'Key'
                            : value.trim(),
                        enabled: !_busy,
                      ),
                    ),
                    Switch(
                      value: key['enabled'] != false,
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => key['enabled'] = value),
                    ),
                    IconButton(
                      tooltip: '移除 ${key['name']}',
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _keys.remove(key);
                              _removedKeyControllers.add(
                                key['controller'] as TextEditingController,
                              );
                            }),
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                  ],
                ),
                TextField(
                  controller: key['controller'] as TextEditingController,
                  enabled: !_busy,
                  obscureText: key['visible'] != true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    hintText: '填写 API Key',
                    suffixIcon: IconButton(
                      tooltip: key['visible'] == true ? '隐藏 Key' : '显示 Key',
                      onPressed: () => setState(
                        () => key['visible'] = key['visible'] != true,
                      ),
                      icon: Icon(
                        key['visible'] == true
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                '启用的 Key 按调用轮询；保存无需连接测试。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Text('模型', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _busy || _loadingKeys || _keysFailed
                        ? null
                        : _fetch,
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('拉取模型'),
                  ),
                  IconButton(
                    tooltip: '手动添加模型',
                    onPressed: _busy ? null : () => _editModel(),
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
              if (_models.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('可拉取模型后勾选添加，也可手动填写模型 ID。供应商可以先保存。'),
                ),
              for (final model in _models)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(modelLabel(model)),
                  subtitle: Text(
                    '${aiProtocols[model['protocol'] ?? _protocol]}${model['vision'] == true ? ' · 图片' : ''}',
                  ),
                  onTap: _busy ? null : () => _editModel(model),
                  trailing: IconButton(
                    tooltip: '移除模型',
                    onPressed: _busy
                        ? null
                        : () => setState(() => _models.remove(model)),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.models, required this.existing});
  final List<Map<String, dynamic>> models;
  final Set<String> existing;
  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  final _selected = <String>{};
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final models = widget.models
        .where(
          (m) => modelLabel(m).toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .72,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Expanded(child: Text('选择要添加的模型')),
                  TextButton(
                    onPressed: () => Navigator.pop(
                      context,
                      widget.models
                          .where((m) => _selected.contains(m['id']))
                          .toList(),
                    ),
                    child: Text('添加 ${_selected.length} 个'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                decoration: const InputDecoration(hintText: '搜索模型 ID'),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: models.length,
                itemBuilder: (_, i) {
                  final model = models[i];
                  final id = model['id'] as String;
                  final exists = widget.existing.contains(id);
                  return CheckboxListTile(
                    title: Text(modelLabel(model)),
                    subtitle: exists ? const Text('已添加，原参数保留') : null,
                    value: exists || _selected.contains(id),
                    onChanged: exists
                        ? null
                        : (v) => setState(() {
                            if (v == true) {
                              _selected.add(id);
                            } else {
                              _selected.remove(id);
                            }
                          }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ModelPage extends StatefulWidget {
  const ModelPage({
    super.key,
    this.model,
    required this.protocol,
    this.existingIds = const {},
  });
  final Map<String, dynamic>? model;
  final String protocol;
  final Set<String> existingIds;
  @override
  State<ModelPage> createState() => _ModelPageState();
}

class _ModelPageState extends State<ModelPage> {
  Map<String, dynamic>? _preset, _undo;
  late Map<String, dynamic> _capabilities = Map<String, dynamic>.from(
    widget.model?['capabilities'] as Map? ?? {},
  );
  late String? _presetId = widget.model?['presetId'] as String?;
  late String? _presetGroup = widget.model?['presetGroup'] as String?;
  late String _variant = widget.model?['presetVariant'] as String? ?? '';
  late final _id = TextEditingController(
    text: widget.model?['id'] as String? ?? '',
  );
  late final _alias = TextEditingController(
    text: widget.model?['alias'] as String? ?? '',
  );
  late final _prompt = TextEditingController(
    text: widget.model?['systemPrompt'] as String? ?? '',
  );
  late String _protocol =
      widget.model?['protocol'] as String? ?? widget.protocol;
  late bool _vision = widget.model?['vision'] == true,
      _inherit = widget.model?['inheritParameters'] == true;
  late final Map<String, dynamic> _params = Map<String, dynamic>.from(
    widget.model?['parameters'] as Map? ?? {},
  );
  late final _controllers = {
    for (final e in {
      'temperature': '0.3',
      'top_p': '1',
      'max_tokens': '8192',
      'reasoning_effort': 'medium',
    }.entries)
      e.key: TextEditingController(text: '${_params[e.key] ?? e.value}'),
  };
  late final _extra = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert(
      {..._params}..removeWhere((key, _) => _controllers.containsKey(key)),
    ),
  );
  late final _enabled = _params.keys.toSet();
  String? _error;
  @override
  void initState() {
    super.initState();
    _restorePreset();
  }

  Future<void> _restorePreset() async {
    if (_presetId == null) return;
    try {
      final list = await loadModelPresets();
      final preset = list
          .where((p) => p['id'] == _presetId && p['group'] == _presetGroup)
          .firstOrNull;
      if (mounted) setState(() => _preset = preset);
    } catch (e) {
      if (mounted) setState(() => _error = '预设资料加载失败，已保存参数保留');
    }
  }

  @override
  void dispose() {
    for (final c in [_id, _alias, _prompt, _extra, ..._controllers.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    try {
      final id = _id.text.trim();
      if (id.isEmpty) throw const FormatException('请填写真实模型 ID');
      if (widget.existingIds.contains(id)) {
        throw const FormatException('这个模型 ID 已存在，请编辑已有模型');
      }
      final params = aiParameters(_extra.text);
      for (final e in _controllers.entries) {
        if (!_enabled.contains(e.key)) continue;
        params[e.key] = e.key == 'reasoning_effort'
            ? e.value.text.trim()
            : num.tryParse(e.value.text.trim()) ?? e.value.text;
      }
      aiParameters(jsonEncode(params));
      Navigator.pop(context, {
        ...?widget.model,
        'id': id,
        'alias': _alias.text.trim(),
        'protocol': _protocol,
        'vision': _vision,
        'inheritParameters': _inherit,
        'parameters': params,
        'systemPrompt': _prompt.text,
        'presetId': _presetId,
        'presetGroup': _presetGroup,
        'presetVariant': _variant,
        'capabilities': _capabilities,
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Map<String, dynamic> _snapshot() {
    final params = aiParameters(_extra.text);
    for (final e in _controllers.entries) {
      if (_enabled.contains(e.key)) {
        params[e.key] = e.key == 'reasoning_effort'
            ? e.value.text.trim()
            : num.tryParse(e.value.text.trim()) ?? e.value.text;
      }
    }
    aiParameters(jsonEncode(params));
    return {
      'id': _id.text,
      'alias': _alias.text,
      'protocol': _protocol,
      'vision': _vision,
      'inheritParameters': _inherit,
      'parameters': params,
      'presetId': _presetId,
      'presetGroup': _presetGroup,
      'presetVariant': _variant,
      'capabilities': _capabilities,
    };
  }

  void _setParameters(Map<String, dynamic> params) {
    _enabled.clear();
    _enabled.addAll(params.keys);
    for (final e in _controllers.entries) {
      if (params[e.key] != null) e.value.text = '${params[e.key]}';
    }
    _extra.text = const JsonEncoder.withIndent('  ').convert(
      {...params}..removeWhere((key, _) => _controllers.containsKey(key)),
    );
  }

  void _changeThinking(String value) {
    try {
      final params = Map<String, dynamic>.from(
        _snapshot()['parameters'] as Map,
      );
      for (final key in [
        'reasoning_effort',
        'reasoning',
        'thinking',
        'output_config',
      ]) {
        params.remove(key);
      }
      final thinking = presetParameters(_preset!, _protocol, value)
        ..remove('max_tokens')
        ..remove('temperature')
        ..remove('store');
      params.addAll(thinking);
      setState(() {
        _variant = value;
        _setParameters(params);
        _error = null;
      });
    } catch (e) {
      setState(() => _error = aiFailureMessage(e));
    }
  }

  Future<void> _choosePreset() async {
    try {
      final before = _snapshot();
      final presets = await loadModelPresets();
      if (!mounted) return;
      final selected = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (_) => _PresetPicker(presets: presets),
      );
      if (selected == null || !mounted) return;
      final apply = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('应用 ${selected['name']}'),
          content: const Text(
            '将填入显示名、图片能力、容量资料和本接口的推荐参数。真实请求 ID 保持原样。可在保存前撤销。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('应用'),
            ),
          ],
        ),
      );
      if (apply != true || !mounted) return;
      final value = applyModelPreset(before, selected, _protocol);
      setState(() {
        _undo = before;
        _preset = selected;
        _variant = '';
        _presetId = selected['id'] as String;
        _presetGroup = selected['group'] as String;
        _alias.text = value['alias'] as String;
        _vision = value['vision'] as bool;
        _inherit = false;
        _capabilities = Map<String, dynamic>.from(value['capabilities'] as Map);
        _setParameters(Map<String, dynamic>.from(value['parameters'] as Map));
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = aiFailureMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('模型配置'),
      actions: [TextButton(onPressed: _save, child: const Text('确定'))],
    ),
    bottomNavigationBar: _status(context, _error, false),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            FieldLabel(
              label: '真实模型 ID（请求时发送）',
              child: TextField(controller: _id),
            ),
            const SizedBox(height: 16),
            FieldLabel(
              label: '别名（仅用于显示，可选）',
              child: TextField(controller: _alias),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('应用模型预设'),
              subtitle: Text(
                _presetId == null ? '一键填入能力与推荐参数，保留请求 ID' : '已应用：$_presetId',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _choosePreset,
            ),
            if (_undo != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() {
                    final before = _undo!;
                    _alias.text = before['alias'] as String;
                    _vision = before['vision'] as bool;
                    _inherit = before['inheritParameters'] as bool;
                    _presetId = before['presetId'] as String?;
                    _presetGroup = before['presetGroup'] as String?;
                    _capabilities = Map<String, dynamic>.from(
                      before['capabilities'] as Map,
                    );
                    _setParameters(
                      Map<String, dynamic>.from(before['parameters'] as Map),
                    );
                    _undo = null;
                    _preset = null;
                    _variant = before['presetVariant'] as String? ?? '';
                    _restorePreset();
                  }),
                  child: const Text('撤销应用预设'),
                ),
              ),
            if (_capabilities.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '上下文 ${_capabilities['contextLimit'] ?? '未标注'} · 最大输出 ${_capabilities['outputLimit'] ?? '未标注'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('图片输入'),
              subtitle: const Text('图片随请求实际发送；供应商也需支持'),
              value: _vision,
              onChanged: (value) => setState(() => _vision = value),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('高级参数'),
              subtitle: const Text('调用协议、输出长度、思考与自定义 JSON'),
              children: [
                SelectionField(
                  label: '调用协议',
                  value: _protocol,
                  options: aiProtocols,
                  onChanged: (value) => setState(() {
                    _protocol = value;
                    _variant = '';
                  }),
                ),
                if (_preset != null &&
                    (_preset!['variants'] as Map? ?? {}).isNotEmpty) ...[
                  const SizedBox(height: 16),
                  SelectionField(
                    label: '预设思考档位',
                    value: _variant,
                    options: {
                      '': '默认（不指定思考参数）',
                      for (final e in (_preset!['variants'] as Map).entries)
                        if (e.value is Map &&
                            presetVariantSupported(
                              Map<String, dynamic>.from(e.value as Map),
                              _protocol,
                            ))
                          e.key as String: e.key as String,
                    },
                    onChanged: _changeThinking,
                  ),
                  const Text('只显示当前接口可转换的档位，原生 Google SDK 专用字段不会发送。'),
                ],
                for (final e in _controllers.entries) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(switch (e.key) {
                      'max_tokens' => '输出长度',
                      'reasoning_effort' => '思考强度（Chat / Responses）',
                      'temperature' => '温度',
                      _ => 'Top P',
                    }),
                    value: _enabled.contains(e.key),
                    onChanged: (value) => setState(() {
                      if (value) {
                        _enabled.add(e.key);
                      } else {
                        _enabled.remove(e.key);
                      }
                    }),
                  ),
                  if (_enabled.contains(e.key))
                    e.key == 'reasoning_effort'
                        ? SelectionField(
                            label: '',
                            value: e.value.text,
                            options: const {
                              'none': 'none',
                              'minimal': 'minimal',
                              'low': 'low',
                              'medium': 'medium',
                              'high': 'high',
                              'max': 'max',
                              'xhigh': 'xhigh',
                            },
                            onChanged: (value) =>
                                setState(() => e.value.text = value),
                          )
                        : TextField(
                            controller: e.value,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                          ),
                ],
                const SizedBox(height: 16),
                FieldLabel(
                  label: '额外 JSON 参数',
                  child: TextField(
                    controller: _extra,
                    minLines: 2,
                    maxLines: 7,
                  ),
                ),
                const SizedBox(height: 10),
                const Text('未启用的常用参数不发送；JSON 内的参数会发送。输出上限仅供参考。'),
                const SizedBox(height: 16),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _PresetPicker extends StatefulWidget {
  const _PresetPicker({required this.presets});
  final List<Map<String, dynamic>> presets;
  @override
  State<_PresetPicker> createState() => _PresetPickerState();
}

class _PresetPickerState extends State<_PresetPicker> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final rows = widget.presets
        .where(
          (p) => '${p['name']} ${p['id']}'.toLowerCase().contains(
            _query.toLowerCase(),
          ),
        )
        .toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: TextField(
              decoration: const InputDecoration(hintText: '搜索预设模型'),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (_, i) {
                final row = rows[i];
                return ListTile(
                  title: Text(row['name'] as String),
                  subtitle: Text(
                    '${row['id']} · ${(row['group'] as String).replaceFirst('@ai-sdk/', '')}',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.pop(context, row),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

Widget? _status(BuildContext context, String? error, bool busy) =>
    error == null && !busy
    ? null
    : SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy) const LinearProgressIndicator(minHeight: 2),
              if (error != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 100),
                  child: SingleChildScrollView(
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
