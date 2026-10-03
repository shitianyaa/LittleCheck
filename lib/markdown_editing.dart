import 'package:flutter/services.dart';

enum MarkdownFormat {
  heading1('一级标题', '# ', '标题', '', true),
  heading2('二级标题', '## ', '标题', '', true),
  heading3('三级标题', '### ', '标题', '', true),
  bold('加粗', '**', '文字', '**'),
  italic('斜体', '*', '文字', '*'),
  strike('删除线', '~~', '文字', '~~'),
  bullet('无序列表', '- ', '列表项', '', true),
  numbered('有序列表', '1. ', '列表项', '', true),
  task('待办', '- [ ] ', '待办事项', '', true),
  quote('引用', '> ', '引用内容', '', true),
  link('链接', '[', '链接文字', '](https://example.com)'),
  image('图片', '![', '图片说明', '](https://example.com/image.png)'),
  code('行内代码', '`', '代码', '`'),
  codeBlock('代码块', '```text\n', '代码', '\n```', true),
  divider('分隔线', '---', '', '', true),
  table('表格', '| ', '列一', ' | 列二 |\n| --- | --- |\n| 内容 | 内容 |', true);

  const MarkdownFormat(
    this.label,
    this.before,
    this.placeholder,
    this.after, [
    this.block = false,
  ]);
  final String label, before, placeholder, after;
  final bool block;
}

/// Inserts around selected text, or selects a placeholder for immediate typing.
TextEditingValue insertMarkdown(TextEditingValue value, MarkdownFormat format) {
  final valid =
      value.selection.isValid && value.selection.end <= value.text.length;
  final start = valid ? value.selection.start : value.text.length;
  final end = valid ? value.selection.end : start;
  final selected = value.text.substring(start, end);
  final content = selected.isEmpty ? format.placeholder : selected;
  String separation(String text, bool before) {
    if (text.isEmpty ||
        (before ? text.endsWith('\n\n') : text.startsWith('\n\n'))) {
      return '';
    }
    return (before ? text.endsWith('\n') : text.startsWith('\n'))
        ? '\n'
        : '\n\n';
  }

  final prefix = format.block
      ? separation(value.text.substring(0, start), true)
      : '';
  final suffix = format.block
      ? separation(value.text.substring(end), false)
      : '';
  if (format == MarkdownFormat.divider && selected.isNotEmpty) {
    final replacement = '$prefix$selected\n\n---$suffix';
    return TextEditingValue(
      text: value.text.replaceRange(start, end, replacement),
      selection: TextSelection.collapsed(
        offset: start + replacement.length - suffix.length,
      ),
    );
  }
  final replacement = '$prefix${format.before}$content${format.after}$suffix';
  final contentStart = start + prefix.length + format.before.length;
  return TextEditingValue(
    text: value.text.replaceRange(start, end, replacement),
    selection: selected.isEmpty && content.isNotEmpty
        ? TextSelection(
            baseOffset: contentStart,
            extentOffset: contentStart + content.length,
          )
        : TextSelection.collapsed(
            offset: start + replacement.length - suffix.length,
          ),
  );
}
