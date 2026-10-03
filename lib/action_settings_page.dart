import 'dart:convert';

import 'package:flutter/material.dart';

import 'ai.dart';
import 'ai_actions.dart';
import 'ai_keys.dart';
import 'provider_page.dart';
import 'selection_field.dart';
import 'storage.dart';

class ActionSettingsPage extends StatefulWidget {
  const ActionSettingsPage({super.key, required this.store});
  final LocalStore store;
  @override
  State<ActionSettingsPage> createState() => _ActionSettingsPageState();
}

class _ActionSettingsPageState extends State<ActionSettingsPage> {
  late final _prompts = {
    for (final action in AiAction.values)
      action.name: TextEditingController(
        text: actionPrompt(widget.store, action),
      ),
  };
  late final _imagePrompt = TextEditingController(
    text: actionPrompt(widget.store, AiAction.translate, images: true),
  );
  late final _parameters = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert(
      widget.store.settings['actionParameters'] ?? {'max_tokens': 8192},
    ),
  );
  late String _reasoning =
      widget.store.settings['actionReasoning'] as String? ?? '';
  late final _roles = <String, String>{
    for (final role in ['main', 'translation', 'vision']) role: _initial(role),
  };
  bool _busy = false;
  String? _error;
  String _initial(String role) {
    final setting = (widget.store.settings['actionModels'] as Map?)?[role];
    if (setting is Map) {
      return jsonEncode([setting['providerId'], setting['modelId']]);
    }
    if (role != 'main') return '';
    try {
      final chosen = actionModel(widget.store, action: AiAction.summary);
      return jsonEncode([chosen.provider['id'], chosen.model['id']]);
    } catch (_) {
      return '';
    }
  }

  Map<String, String> get _choices => {
    for (final provider in providers(widget.store))
      for (final model in providerModels(provider))
        jsonEncode([provider['id'], model['id']]):
            '${provider['name']} · ${modelLabel(model)}',
  };

  @override
  void dispose() {
    for (final c in [..._prompts.values, _imagePrompt, _parameters]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final roles = <String, dynamic>{};
      for (final role in _roles.entries) {
        if (role.value.isEmpty) {
          if (role.key == 'main') {
            throw const FormatException('请选择主模型，或先添加供应商和模型');
          }
          roles[role.key] = null;
          continue;
        }
        if (!_choices.containsKey(role.value)) {
          throw const FormatException('选择的模型已移除，请重新选择');
        }
        final pair = jsonDecode(role.value) as List;
        roles[role.key] = {'providerId': pair[0], 'modelId': pair[1]};
      }
      for (final prompt in [..._prompts.values, _imagePrompt]) {
        validateActionPrompt(prompt.text);
      }
      await widget.store.setSettings(
        extra: {
          'actionModels': roles,
          'actionPrompts': {
            for (final e in _prompts.entries) e.key: e.value.text,
          },
          'imageTranslationPrompt': _imagePrompt.text,
          'actionParameters': aiParameters(_parameters.text),
          'actionReasoning': _reasoning,
          'defaultProvider': roles['main']['providerId'],
          'defaultModel': roles['main']['modelId'],
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = aiFailureMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('AI 功能'),
      actions: [
        TextButton(onPressed: _busy ? null : _save, child: const Text('保存')),
      ],
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SelectionField(
              label: '主模型',
              value: _roles['main'],
              options: {'': '请选择模型', ..._choices},
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _roles['main'] = value),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ProviderPage(store: widget.store),
                          ),
                        );
                        if (mounted) setState(() {});
                      },
                icon: const Icon(Icons.add_rounded, size: 17),
                label: const Text('添加供应商'),
              ),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('专用模型'),
              subtitle: const Text('未配置时沿用主模型'),
              children: [
                SelectionField(
                  label: '文字翻译模型',
                  value: _roles['translation'],
                  options: {'': '沿用主模型', ..._choices},
                  onChanged: _busy
                      ? null
                      : (value) =>
                            setState(() => _roles['translation'] = value),
                ),
                const SizedBox(height: 16),
                SelectionField(
                  label: '识图模型',
                  value: _roles['vision'],
                  options: {'': '沿用主模型', ..._choices},
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _roles['vision'] = value),
                ),
                const SizedBox(height: 12),
                const Text('附加图片的翻译和总结使用识图模型；模型需支持图片输入。'),
                const SizedBox(height: 12),
              ],
            ),
            const SizedBox(height: 12),
            for (final action in AiAction.values) ...[
              FieldLabel(
                label: '${action.label}提示词',
                child: TextField(
                  key: ValueKey('prompt:${action.name}'),
                  controller: _prompts[action.name],
                  enabled: !_busy,
                  minLines: 3,
                  maxLines: 7,
                ),
              ),
              const SizedBox(height: 16),
            ],
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('图片文字翻译提示词'),
              children: [
                TextField(
                  controller: _imagePrompt,
                  enabled: !_busy,
                  minLines: 3,
                  maxLines: 7,
                ),
                const SizedBox(height: 12),
              ],
            ),
            Text(
              '可用 {source_text}、{target_lang}、{action}。不写 {source_text} 时自动附加正文。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('默认请求参数'),
              subtitle: const Text('思考强度与输出长度，模型独立配置优先'),
              children: [
                SelectionField(
                  label: '默认思考强度',
                  value: _reasoning,
                  options: const {
                    '': '自动（不指定）',
                    'none': 'none',
                    'low': 'low',
                    'medium': 'medium',
                    'high': 'high',
                    'xhigh': 'xhigh',
                    'max': 'max',
                  },
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _reasoning = value),
                ),
                const SizedBox(height: 16),
                FieldLabel(
                  label: '默认 JSON 参数',
                  child: TextField(
                    controller: _parameters,
                    enabled: !_busy,
                    minLines: 2,
                    maxLines: 7,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '已应用预设的模型按其支持档位转换。未知模型的 Chat / Responses 按所选强度发送；其他协议请在模型中配置。',
                ),
                const SizedBox(height: 12),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
          ],
        ),
      ),
    ),
  );
}
