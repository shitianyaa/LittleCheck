import 'package:flutter_test/flutter_test.dart';
import 'package:little_check/tasks.dart';

void main() {
  test(
    'toggle changes only the selected duplicate task and preserves CRLF',
    () {
      const source = '- [ ] 一样\r\n- [ ] 一样\r\n';
      final tasks = MarkdownTasks.parse(source);
      expect(tasks, hasLength(2));
      expect(
        MarkdownTasks.toggle(source, tasks.last.offset),
        '- [ ] 一样\r\n- [x] 一样\r\n',
      );
    },
  );
  test(
    'fenced and indented code never becomes a task even with duplicate labels',
    () {
      const source = '```md\n- [ ] 一样\n```\n\n    - [ ] 一样\n\n- [ ] 一样\n';
      final tasks = MarkdownTasks.parse(source);
      expect(tasks, hasLength(1));
      expect(
        MarkdownTasks.toggle(source, tasks.single.offset),
        '```md\n- [ ] 一样\n```\n\n    - [ ] 一样\n\n- [x] 一样\n',
      );
    },
  );
  test('nested ordered and quoted tasks have distinct valid offsets', () {
    const source = '- [ ] **父项**\n  - [x] 子项\n\n> 1. [ ] 引用任务\n';
    final tasks = MarkdownTasks.parse(source);
    expect(tasks.map((task) => task.checked), [false, true, false]);
    expect(
      MarkdownTasks.toggle(source, tasks[1].offset),
      '- [ ] **父项**\n  - [ ] 子项\n\n> 1. [ ] 引用任务\n',
    );
  });
  test('ordinary checkbox text and tilde code fences are excluded', () {
    const source = '文字 [ ]\n\n~~~\n- [x] 假任务\n~~~\n\n- [X] 真任务\n';
    expect(MarkdownTasks.parse(source).map((task) => task.checked), [true]);
  });
}
