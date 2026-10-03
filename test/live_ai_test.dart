import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/ai.dart';

class _LiveHttp extends HttpOverrides {}

void main() {
  final base = Platform.environment['LITTLE_CHECK_TEST_BASE'];
  final key = Platform.environment['LITTLE_CHECK_TEST_KEY'];
  for (final protocol in aiProtocols.keys) {
    test(
      'live $protocol image input',
      () async {
        final old = HttpOverrides.current;
        HttpOverrides.global = _LiveHttp();
        addTearDown(() => HttpOverrides.global = old);
        final client = AiClient();
        addTearDown(client.close);
        final model = protocol == 'messages'
            ? 'claude-sonnet-4-6'
            : 'gemini-3.1-flash-lite';
        final answer = await client.chat(
          provider: {'baseUrl': base!, 'protocol': protocol, 'model': model},
          key: key!,
          parameters: {'max_tokens': 256},
          messages: [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '这张图片主要是什么颜色？请仅回答一句中文。'},
                {
                  'type': 'image_url',
                  'image_url': {
                    'url': 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAAM0lEQVR4nO3RwQ0AMAjDwJTJGb0jmE9+vgGCZF6yaZrqejxw4A+QiZCJkImQiZCJUD3RB24jALCu/Sv2AAAAAElFTkSuQmCC',
                  },
                },
              ],
            },
          ],
        );
        expect(answer.trim(), isNotEmpty);
        expect(answer, contains('蓝'));
      },
      skip: base == null || key == null
          ? 'Requires temporary process credentials'
          : false,
      timeout: const Timeout(Duration(minutes: 2)),
    );
    test(
      'live $protocol model listing and conversation',
      () async {
        final old = HttpOverrides.current;
        HttpOverrides.global = _LiveHttp();
        addTearDown(() => HttpOverrides.global = old);
        final client = AiClient();
        addTearDown(client.close);
        final provider = {'baseUrl': base!, 'protocol': protocol};
        final models = await client.fetchModels(provider, key!);
        expect(models, isNotEmpty);
        final preferred = protocol == 'messages'
            ? 'claude-sonnet-4-6'
            : 'gemini-3.1-flash-lite';
        expect(models.any((m) => m['id'] == preferred), isTrue);
        final messages = <Map<String, dynamic>>[
          {'role': 'system', 'content': '这是应用接口测试，请用简体中文简短回答。'},
          {'role': 'user', 'content': '只回复：测试通过'},
        ];
        final parameters = <String, dynamic>{'max_tokens': 128};
        final answer = await client.chat(
          provider: {...provider, 'model': preferred},
          key: key,
          messages: messages,
          parameters: parameters,
        );
        expect(answer.trim(), isNotEmpty);
        messages.addAll([
          {'role': 'assistant', 'content': answer},
          {'role': 'user', 'content': '刚才我让你回复什么？'},
        ]);
        final followup = await client.chat(
          provider: {...provider, 'model': preferred},
          key: key,
          messages: messages,
          parameters: parameters,
        );
        expect(followup.trim(), isNotEmpty);
      },
      skip: base == null || key == null
          ? 'Only run with temporary test credentials in process environment'
          : false,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
