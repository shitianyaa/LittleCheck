import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

Future<List<Map<String, dynamic>>> loadModelPresets() async {
  final data = jsonDecode(
    await rootBundle.loadString('assets/ai/preset_models.json'),
  ) as Map<String, dynamic>;
  return [
    for (final group in data.entries)
      for (final item in group.value as List)
        {...Map<String, dynamic>.from(item as Map), 'group': group.key},
  ];
}

Map<String, dynamic> presetParameters(
  Map<String, dynamic> preset,
  String protocol, [
  String? variant,
]) {
  final parameters = <String, dynamic>{
    'max_tokens': min(preset['outputLimit'] as int? ?? 8192, 8192),
    if (preset['temperature'] == true) 'temperature': 0.3,
    if (protocol == 'responses') 'store': false,
  };
  final option = preset['options'] as Map? ?? {};
  if (option['store'] is bool && protocol == 'responses') {
    parameters['store'] = option['store'];
  }
  final chosen = (preset['variants'] as Map? ?? {})[variant];
  if (chosen is! Map) return parameters;
  final effort = chosen['reasoningEffort'];
  if (effort is String) {
    if (protocol == 'chat') parameters['reasoning_effort'] = effort;
    if (protocol == 'responses') parameters['reasoning'] = {'effort': effort};
  }
  if (protocol == 'messages') {
    if (chosen['thinking'] is Map) {
      parameters['thinking'] = Map<String, dynamic>.from(
        chosen['thinking'] as Map,
      );
    }
    if (chosen['effort'] is String) {
      parameters['output_config'] = {'effort': chosen['effort']};
    }
  }
  return parameters;
}

bool presetVariantSupported(Map<String, dynamic> variant, String protocol) =>
    protocol == 'messages'
    ? variant['thinking'] is Map || variant['effort'] is String
    : variant['reasoningEffort'] is String;

Map<String, dynamic> applyModelPreset(
  Map<String, dynamic> model,
  Map<String, dynamic> preset,
  String protocol,
) => {
  ...model,
  // A gateway may rename models; capability presets never rewrite its request ID.
  'id': model['id'] ?? '',
  'alias': preset['name'],
  'presetId': preset['id'],
  'presetGroup': preset['group'],
  'protocol': protocol,
  'vision': ((preset['modalities'] as Map?)?['input'] as List? ?? []).contains(
    'image',
  ),
  'inheritParameters': false,
  'parameters': presetParameters(preset, protocol),
  'capabilities': {
    for (final key in [
      'contextLimit',
      'outputLimit',
      'modalities',
      'reasoning',
      'temperature',
    ])
      if (preset[key] != null) key: preset[key],
    'reasoningProfiles': {
      for (final api in ['chat', 'responses', 'messages'])
        api: {
          for (final entry in (preset['variants'] as Map? ?? {}).entries)
            if (entry.value is Map &&
                presetVariantSupported(
                  Map<String, dynamic>.from(entry.value as Map),
                  api,
                ))
              entry.key: (presetParameters(preset, api, entry.key as String)
                ..remove('max_tokens')
                ..remove('temperature')
                ..remove('store')),
        },
    },
  },
};
