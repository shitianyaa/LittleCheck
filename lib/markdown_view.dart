import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import 'feed.dart';
import 'image_cache.dart';
import 'tasks.dart';

class MarkdownView extends StatelessWidget {
  const MarkdownView({super.key, required this.content, this.onToggle});
  final String content;
  final ValueChanged<int>? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tasks = MarkdownTasks.parse(content);
    final builder = _TaskBuilder(tasks, onToggle);
    final style = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.65),
      h1: theme.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w600,
        fontSize: 23,
        height: 1.4,
      ),
      h2: theme.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        fontSize: 19,
        height: 1.5,
      ),
      h3: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.5,
      ),
      blockSpacing: 12,
      listIndent: 30,
      listBulletPadding: const EdgeInsets.only(right: 6),
      listBullet: theme.textTheme.bodyLarge?.copyWith(
        fontSize: 15,
        height: 1.65,
      ),
      codeblockDecoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
      ),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
        color: theme.colorScheme.surfaceContainerLow,
      ),
      blockquotePadding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 8,
      ),
    );
    return MarkdownBody(
      // The renderer reparses data/style changes but caches checkbox callbacks.
      // Recreate it when saving switches tasks between disabled and interactive.
      key: ValueKey(onToggle != null),
      data: content,
      selectable: true,
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.start,
      styleSheet: style,
      builders: {'input': builder},
      checkboxBuilder: builder.listCheckbox,
      imageBuilder: (uri, title, alt) {
        if (!['http', 'https'].contains(uri.scheme) ||
            uri.userInfo.isNotEmpty) {
          return Text(alt ?? '暂不支持本地图片');
        }
        return CachedNetworkImage(
          imageUrl: uri.toString(),
          cacheManager: imageFileCache,
          memCacheWidth: 720,
          fit: BoxFit.contain,
          fadeInDuration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 120),
          fadeOutDuration: Duration.zero,
          placeholder: (context, _) => Container(
            height: 160,
            alignment: Alignment.center,
            color: theme.colorScheme.surfaceContainerLow,
            child: Icon(
              Icons.image_outlined,
              color: theme.colorScheme.onSurfaceVariant,
              semanticLabel: '图片加载中',
            ),
          ),
          errorWidget: (_, _, _) =>
              Text(alt == null || alt.isEmpty ? '图片加载失败' : '图片加载失败：$alt'),
        );
      },
      onTapLink: (_, href, _) async {
        if (href == null) return;
        try {
          final url = httpUri(href);
          if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
            throw const FormatException('无法打开链接');
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('$e')));
          }
        }
      },
    );
  }
}

class _TaskBuilder extends MarkdownElementBuilder {
  _TaskBuilder(this.tasks, this.onToggle)
    : tightTasks = tasks.where((task) => !task.inline).toList()
        ..sort((a, b) => a.renderOrder.compareTo(b.renderOrder));
  final List<MarkdownTask> tasks;
  final List<MarkdownTask> tightTasks;
  final ValueChanged<int>? onToggle;
  var _index = 0;
  var _tightIndex = 0;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final task = _index < tasks.length ? tasks[_index++] : null;
    return task?.inline == true
        ? checkbox(element.attributes.containsKey('checked'), task!.offset)
        : const SizedBox.shrink();
  }

  // Tight list bullets are built after their children; nested lists therefore
  // need AST postorder, while inline inputs follow normal source order.
  Widget listCheckbox(bool checked) {
    final task = _tightIndex < tightTasks.length
        ? tightTasks[_tightIndex++]
        : null;
    return checkbox(checked, task?.offset);
  }

  Widget checkbox(bool checked, int? offset) => SizedBox(
    width: 24,
    height: 25,
    child: Checkbox(
      key: offset == null ? null : ValueKey('task:$offset'),
      value: checked,
      semanticLabel: checked ? '已完成待办，点击取消' : '未完成待办，点击完成',
      onChanged: onToggle == null || offset == null
          ? null
          : (_) => onToggle!(offset),
    ),
  );
}
