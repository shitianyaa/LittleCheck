import 'ai.dart';

final _keyPositions = <String, int>{};

List<Map<String, dynamic>> providerKeys(Map<String, dynamic> provider) =>
    (provider['keys'] as List? ?? [])
        .map((key) => Map<String, dynamic>.from(key as Map))
        .toList();

String providerKeyName(String providerId, String keyId) =>
    'provider:$providerId:$keyId';

Future<String> nextProviderKey(Map<String, dynamic> provider) async {
  final id = provider['id'] as String;
  if (provider['keys'] == null) {
    final legacy = await secureKeys.read(key: 'provider:$id');
    if (legacy == null || legacy.trim().isEmpty) {
      throw const FormatException('请在供应商设置中添加 API Key');
    }
    return legacy;
  }
  final keys = providerKeys(provider)
      .where((k) => k['enabled'] != false)
      .toList();
  if (keys.isEmpty) throw const FormatException('请至少启用一个 API Key');
  final position = _keyPositions[id] ?? 0;
  _keyPositions[id] = position + 1;
  final selected = keys[position % keys.length];
  final value = await secureKeys.read(
    key: providerKeyName(id, selected['id'] as String),
  );
  if (value == null || value.trim().isEmpty) {
    throw FormatException('API Key「${selected['name']}」缺失，请重新填写');
  }
  return value;
}

String aiFailureMessage(Object error) {
  if (error is FormatException) return error.message;
  return '$error'.replaceFirst(RegExp(r'^(?:HttpException|Exception):\s*'), '');
}
