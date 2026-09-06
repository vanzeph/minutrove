import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'tokens.dart';
import 'trove_icon.dart';

/// Presentation only. Features translate their domain type to this label.
enum TileKind { quest, award }

class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.name,
    required this.kind,
    required this.iconKey,
    required this.palette,
    required this.summary,
    required this.onActivate,
    required this.onConfigure,
  });
  final String name;
  final TileKind kind;
  final String iconKey;
  final ItemPalette palette;
  final String summary;
  final VoidCallback? onActivate;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final label = '${kind == TileKind.quest ? 'Quest' : 'Award'} · $summary';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          enabled: onActivate != null,
          label: '$name, $label',
          onTap: onActivate,
          customSemanticsActions: {
            const CustomSemanticsAction(label: 'Configure'): onConfigure,
          },
          excludeSemantics: true,
          child: Tooltip(
            message: 'Tap to open. Double tap to configure.',
            child: InkWell(
              onTap: onActivate,
              onDoubleTap: onConfigure,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ItemIcon(iconKey: iconKey, palette: palette),
                    const SizedBox(height: 6),
                    Text(
                      name,
                      style: TroveTokens.label,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      label,
                      style: TroveTokens.small.copyWith(
                        color: TroveTokens.muted,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        TextButton(
          onPressed: onConfigure,
          child: Text(
            'Configure',
            textAlign: TextAlign.center,
            semanticsLabel: 'Configure $name',
          ),
        ),
      ],
    );
  }
}

/// Wrapping children with natural height prevents clipped labels at large text.
class ItemTileGroup extends StatelessWidget {
  const ItemTileGroup({super.key, required this.title, required this.children});
  final String title;
  final List<ItemTile> children;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(header: true, child: Text(title, style: TroveTokens.heading)),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, constraints) {
          final desired = MediaQuery.textScalerOf(context).scale(14) > 20
              ? 160.0
              : 92.0;
          final count = ((constraints.maxWidth + 20) / (desired + 20))
              .floor()
              .clamp(1, 6);
          final width = (constraints.maxWidth - (count - 1) * 20) / count;
          return Wrap(
            spacing: 20,
            runSpacing: 12,
            children: [
              for (final child in children)
                SizedBox(width: width, child: child),
            ],
          );
        },
      ),
    ],
  );
}
