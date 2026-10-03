import 'package:flutter/material.dart';

/// Labels stay outside the field; choices never change its geometry.
class SelectionField extends StatelessWidget {
  const SelectionField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.icon,
    this.compact = false,
  });
  final String label;
  final String? value;
  final Map<String, String> options;
  final ValueChanged<String>? onChanged;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (label.isNotEmpty) ...[
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
      ],
      Material(
        color: compact
            ? Theme.of(context).colorScheme.surfaceContainerLow
            : Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(compact ? 24 : 10),
          side: compact
              ? BorderSide.none
              : BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onChanged == null
              ? null
              : () async {
                  FocusManager.instance.primaryFocus?.unfocus();
                  final selected = await showModalBottomSheet<String>(
                    context: context,
                    showDragHandle: true,
                    useSafeArea: true,
                    isScrollControlled: true,
                    builder: (context) => ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * .65,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (label.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                              child: Text(
                                label,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          Flexible(
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                for (final entry in options.entries)
                                  ListTile(
                                    title: Text(entry.value),
                                    trailing: value == entry.key
                                        ? const Icon(Icons.check_rounded)
                                        : null,
                                    selected: value == entry.key,
                                    onTap: () =>
                                        Navigator.pop(context, entry.key),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                  if (selected != null &&
                      selected != value &&
                      context.mounted) {
                    onChanged!(selected);
                  }
                },
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: compact ? 10 : 14,
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    options[value] ?? '请选择',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                const Icon(Icons.keyboard_arrow_down_rounded, size: 22),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

class SearchField extends StatelessWidget {
  const SearchField({super.key, required this.hint, required this.onChanged});
  final String hint;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => TextField(
    onChanged: onChanged,
    decoration: InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
      prefixIcon: const Icon(Icons.search_rounded, size: 21),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.primary,
          width: 1,
        ),
      ),
    ),
  );
}

class FieldLabel extends StatelessWidget {
  const FieldLabel({super.key, required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 8),
      child,
    ],
  );
}
