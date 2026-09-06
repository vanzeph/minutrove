import 'package:flutter/material.dart';

import 'core.dart';

/// Synthetic integration surface for reviewing shared widgets without storage.
/// Open explicitly from a development harness; never seeds product data.
class ComponentGallery extends StatefulWidget {
  const ComponentGallery({super.key});
  @override
  State<ComponentGallery> createState() => _ComponentGalleryState();
}

class _ComponentGalleryState extends State<ComponentGallery> {
  int _destination = 0;
  String _icon = 'gamepad';
  ItemPalette _palette = ItemPalette.presets[1];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Minutrove')),
    bottomNavigationBar: TroveNavigationBar(
      selectedIndex: _destination,
      onDestinationSelected: (value) => setState(() => _destination = value),
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const WalletDisplay(coins: 420123456, gems: 18000000),
            const SizedBox(height: 20),
            ItemTileGroup(
              title: 'Make progress',
              children: [
                ItemTile(
                  name: 'Read',
                  kind: TileKind.quest,
                  iconKey: 'book',
                  palette: ItemPalette.presets[0],
                  summary: '20m',
                  onActivate: _previewAction,
                  onConfigure: _configure,
                ),
                ItemTile(
                  name: 'Practice',
                  kind: TileKind.quest,
                  iconKey: _icon,
                  palette: _palette,
                  summary: '25m',
                  onActivate: _previewAction,
                  onConfigure: _configure,
                ),
                ItemTile(
                  name: 'Gaming',
                  kind: TileKind.award,
                  iconKey: _icon,
                  palette: _palette,
                  summary: '45m',
                  onActivate: _previewAction,
                  onConfigure: _configure,
                ),
              ],
            ),
            const SizedBox(height: 20),
            ItemTileGroup(
              title: 'Look forward',
              children: [
                ItemTile(
                  name: 'Getaway',
                  kind: TileKind.award,
                  iconKey: 'palm-tree',
                  palette: ItemPalette.presets[3],
                  summary: '2d · USD 400',
                  onActivate: _previewAction,
                  onConfigure: _configure,
                ),
              ],
            ),
            const SizedBox(height: 20),
            TroveButton(
              label: 'Choose icon',
              onPressed: () async {
                final key = await showIconPicker(
                  context: context,
                  selectedKey: _icon,
                  palette: _palette,
                );
                if (key != null && mounted) setState(() => _icon = key);
              },
            ),
            const SizedBox(height: 8),
            TroveButton(
              label: 'Choose color',
              secondary: true,
              onPressed: () async {
                final color = await showItemColorPicker(
                  context: context,
                  color: _palette.accent,
                  iconKey: _icon,
                );
                if (color != null && mounted) {
                  setState(() => _palette = ItemPalette.custom(color));
                }
              },
            ),
            const SizedBox(height: 20),
            const Text(
              'Component preview · Synthetic values',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );

  void _previewAction() => ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Preview only. No activity or balance changed.'),
    ),
  );

  void _configure() => showTroveDialog<void>(
    context: context,
    title: 'Configure item',
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const TroveTextField(label: 'Item name', initialValue: 'Practice'),
        const SizedBox(height: 16),
        const TroveFormRow(
          children: [
            TroveTextField(label: 'Coins / minute', initialValue: '2'),
            TroveTextField(label: 'Gems / minute', initialValue: '0.04'),
          ],
        ),
        const SizedBox(height: 16),
        const TroveTextField(
          label: 'Daily goal · optional',
          initialValue: '120',
        ),
        const SizedBox(height: 16),
        const Text('Changes apply to future sessions.'),
        const SizedBox(height: 20),
        TroveButton(
          label: 'Close preview',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );
}
