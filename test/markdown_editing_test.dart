import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/markdown_editing.dart';

void main() {
  test('every text format inserts and selects an editable placeholder', () {
    for (final format in MarkdownFormat.values) {
      final result = insertMarkdown(
        const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        ),
        format,
      );
      expect(
        result.text,
        '${format.before}${format.placeholder}${format.after}',
      );
      expect(result.selection.textInside(result.text), format.placeholder);
    }
  });
  test('wraps selected text without losing adjacent content', () {
    final result = insertMarkdown(
      const TextEditingValue(
        text: 'before word after',
        selection: TextSelection(baseOffset: 11, extentOffset: 7),
      ),
      MarkdownFormat.bold,
    );
    expect(result.text, 'before **word** after');
  });
  test(
    'block format separates a paragraph and selects only its placeholder',
    () {
      final result = insertMarkdown(
        const TextEditingValue(
          text: '左右',
          selection: TextSelection.collapsed(offset: 1),
        ),
        MarkdownFormat.codeBlock,
      );
      expect(result.text, '左\n\n```text\n代码\n```\n\n右');
      expect(result.selection.textInside(result.text), '代码');
    },
  );
  test('invalid selection safely inserts at the end', () {
    final result = insertMarkdown(
      const TextEditingValue(text: 'keep'),
      MarkdownFormat.task,
    );
    expect(result.text, 'keep\n\n- [ ] 待办事项');
  });
  test('divider preserves selected content and stays on its own line', () {
    final result = insertMarkdown(
      const TextEditingValue(
        text: 'keep',
        selection: TextSelection(baseOffset: 0, extentOffset: 4),
      ),
      MarkdownFormat.divider,
    );
    expect(result.text, 'keep\n\n---');
  });
}
