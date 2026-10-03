import 'package:markdown/markdown.dart' as md;

class MarkdownTask {
  const MarkdownTask(
    this.offset,
    this.checked, {
    this.inline = false,
    this.renderOrder = 0,
  });
  final int offset;
  final bool checked;
  final bool inline;
  final int renderOrder;
}

/// The parser decides which list items are tasks; source offsets preserve text.
class MarkdownTasks {
  static final _candidate = RegExp(
    r'^(?:[ \t]*>[ \t]?)*[ \t]*(?:[-+*]|\d+[.)])[ \t]+\[([ xX])\](?=[ \t]|$)',
    multiLine: true,
  );

  static List<MarkdownTask> parse(String source) {
    final candidates = _candidate.allMatches(source).toList();
    var marker = '\uE000LC';
    while (source.contains(marker)) {
      marker += 'C';
    }
    // Annotate only the parser input. Its AST excludes fenced/indented code,
    // while these unique markers retain the original character positions.
    final buffer = StringBuffer();
    var start = 0;
    for (var index = 0; index < candidates.length; index++) {
      final offset = candidates[index].end;
      buffer.write(source.substring(start, offset));
      buffer.write(' $marker$index\uE001 ');
      start = offset;
    }
    buffer.write(source.substring(start));
    final nodes = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored)
        .parseLines(buffer.toString().split(RegExp(r'\r?\n')));
    final tasks = <MarkdownTask>[];
    final markerPattern = RegExp('${RegExp.escape(marker)}(\\d+)\uE001');
    void visit(md.Node node) {
      if (node is! md.Element) return;
      for (final child in node.children ?? <md.Node>[]) {
        visit(child);
      }
      if (node.tag != 'li' || node.children?.isNotEmpty != true) return;
      var input = node.children!.first;
      final inline = input is md.Element && input.tag == 'p';
      if (inline && input.children?.isNotEmpty == true) {
        input = input.children!.first;
      }
      if (input is md.Element &&
          input.tag == 'input' &&
          input.attributes['type'] == 'checkbox') {
        final markerMatch = markerPattern.firstMatch(node.textContent);
        if (markerMatch != null) {
          final match = candidates[int.parse(markerMatch.group(1)!)];
          tasks.add(
            MarkdownTask(
              match.end - 2,
              input.attributes.containsKey('checked'),
              inline: inline,
              renderOrder: tasks.length,
            ),
          );
        }
      }
    }

    for (final node in nodes) {
      visit(node);
    }
    tasks.sort((a, b) => a.offset.compareTo(b.offset));
    return tasks;
  }

  static String toggle(String source, int offset) {
    if (!parse(source).any((task) => task.offset == offset)) {
      throw const FormatException('任务位置已变化，请重新打开笔记');
    }
    return source.replaceRange(
      offset,
      offset + 1,
      source[offset] == ' ' ? 'x' : ' ',
    );
  }
}
