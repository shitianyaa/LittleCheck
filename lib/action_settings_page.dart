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

  @override
  void initState() {
    super.initState();
    // 监听输入变化，让「默认预设 / 已自定义」标签随编辑实时刷新。
    for (final controller in [..._prompts.values, _imagePrompt]) {
      controller.addListener(_onPromptChanged);
    }
  }

  void _onPromptChanged() {
    if (mounted) setState(() {});
  }

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

  bool _isDefaultPrompt(String actionName) {
    final current = _prompts[actionName]?.text.trim();
    final def = defaultActionPrompts[actionName]?.trim();
    return current == def;
  }

  bool get _isDefaultImagePrompt {
    final current = _imagePrompt.text.trim();
    final def = defaultImageTranslationPrompt.trim();
    return current == def;
  }

  void _resetPrompt(String actionName) {
    final def = defaultActionPrompts[actionName];
    if (def != null) {
      setState(() {
        _prompts[actionName]?.text = def;
      });
    }
  }

  void _resetImagePrompt() {
    setState(() {
      _imagePrompt.text = defaultImageTranslationPrompt;
    });
  }

  @override
  void dispose() {
    for (final c in [..._prompts.values, _imagePrompt]) {
      c.removeListener(_onPromptChanged);
    }
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

  Widget _section(String title, {String? subtitle}) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
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

  Widget _card({required Widget child}) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  Widget _variableTag(String tag, String desc) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(
        color: Theme.of(context).colorScheme.outlineVariant
            .withValues(alpha: .5),
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          tag,
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            desc,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _promptCard({
    required Key? key,
    required String title,
    required TextEditingController controller,
    required bool isDefault,
    required VoidCallback onReset,
  }) => _card(
    child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        initiallyExpanded: true,
        maintainState: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        title: Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          isDefault ? '默认预设' : '已自定义',
          style: TextStyle(
            fontSize: 12,
            color: isDefault
                ? Theme.of(context).colorScheme.onSurfaceVariant
                : Theme.of(context).colorScheme.primary,
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          TextField(
            key: key,
            controller: controller,
            enabled: !_busy,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: _busy || isDefault ? null : onReset,
                icon: const Icon(Icons.restore_rounded, size: 16),
                label: const Text('恢复默认', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    ),
  );

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
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            _section('模型配置', subtitle: '配置默认模型与专用任务模型'),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('主模型', style: Theme.of(context).textTheme.labelMedium),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
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
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('添加供应商', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
            SelectionField(
              label: '',
              value: _roles['main'],
              options: {'': '请选择模型', ..._choices},
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _roles['main'] = value),
            ),
            const SizedBox(height: 12),
            _card(
              child: Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  shape: const Border(),
                  collapsedShape: const Border(),
                  tilePadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                  leading: const Icon(Icons.tune_rounded, size: 20),
                  title: const Text(
                    '专用模型设置',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  subtitle: const Text(
                    '未配置时沿用主模型',
                    style: TextStyle(fontSize: 12),
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
                    const SizedBox(height: 14),
                    SelectionField(
                      label: '识图模型',
                      value: _roles['vision'],
                      options: {'': '沿用主模型', ..._choices},
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _roles['vision'] = value),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '附加图片的翻译和总结使用识图模型；模型需支持图片输入。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _section('推理与参数', subtitle: '调节模型思考深度与底层接口配置'),
            SelectionField(
              label: '默认思考强度',
              value: _reasoning,
              icon: Icons.psychology_outlined,
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
            const SizedBox(height: 12),
            _card(
              child: Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  shape: const Border(),
                  collapsedShape: const Border(),
                  tilePadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                  leading: const Icon(Icons.data_object_rounded, size: 20),
                  title: const Text(
                    '高级 JSON 参数',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  subtitle: const Text(
                    'max_tokens 与自定义协议参数',
                    style: TextStyle(fontSize: 12),
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    TextField(
                      controller: _parameters,
                      enabled: !_busy,
                      minLines: 2,
                      maxLines: 7,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '已应用预设的模型按其支持档位转换。未知模型的 Chat / Responses 按所选强度发送；其他协议请在模型中配置。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _section('功能提示词', subtitle: '为各项 AI 功能自定义系统 Prompt'),
            _card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '提示词模板支持以下动态变量；不显式编写 {source_text} 时会自动附加正文：',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _variableTag('{source_text}', '原文正文'),
                        _variableTag('{target_lang}', '目标语言'),
                        _variableTag('{action}', '操作指令'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (final action in AiAction.values) ...[
              _promptCard(
                key: ValueKey('prompt:${action.name}'),
                title: '${action.label}提示词',
                controller: _prompts[action.name]!,
                isDefault: _isDefaultPrompt(action.name),
                onReset: () => _resetPrompt(action.name),
              ),
              const SizedBox(height: 10),
            ],
            _promptCard(
              key: null,
              title: '图片文字翻译提示词',
              controller: _imagePrompt,
              isDefault: _isDefaultImagePrompt,
              onReset: _resetImagePrompt,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer
                        .withValues(alpha: .3),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.error
                          .withValues(alpha: .5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        size: 20,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 13,
                          ),
                        ),
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
