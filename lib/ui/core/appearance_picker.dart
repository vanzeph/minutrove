import 'package:flutter/material.dart';

import 'icon_catalog.dart';
import 'surfaces.dart';
import 'tokens.dart';
import 'trove_icon.dart';

Future<String?> showIconPicker({
  required BuildContext context,
  required String selectedKey,
  required ItemPalette palette,
}) => showDialog<String>(
  context: context,
  builder: (_) => IconPickerDialog(selectedKey: selectedKey, palette: palette),
);

class IconPickerDialog extends StatefulWidget {
  const IconPickerDialog({
    super.key,
    required this.selectedKey,
    required this.palette,
  });
  final String selectedKey;
  final ItemPalette palette;
  @override
  State<IconPickerDialog> createState() => _IconPickerDialogState();
}

class _IconPickerDialogState extends State<IconPickerDialog> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final results = IconCatalog.search(_query);
    return TroveDialog(
      title: 'Choose icon',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TroveTextField(
            label: 'Search icons',
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 12),
          Text(
            '${results.length} icons',
            semanticsLabel: '${results.length} matching icons',
          ),
          const SizedBox(height: 12),
          if (results.isEmpty)
            const Text('No icons found. Try another activity or object.'),
          LayoutBuilder(
            builder: (context, constraints) {
              final large = MediaQuery.textScalerOf(context).scale(14) > 20;
              final columns = (constraints.maxWidth / (large ? 120 : 90))
                  .floor()
                  .clamp(1, 4);
              final width =
                  (constraints.maxWidth - (columns - 1) * 8) / columns;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final icon in results)
                    SizedBox(
                      width: width,
                      child: Semantics(
                        selected: icon.key == widget.selectedKey,
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(icon.key),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TroveIcon(icon.key, color: TroveTokens.ink),
                              const SizedBox(height: 8),
                              Text(icon.label, textAlign: TextAlign.center),
                              if (icon.key == widget.selectedKey)
                                const Text('Selected'),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

Future<Color?> showItemColorPicker({
  required BuildContext context,
  required Color color,
  required String iconKey,
}) => showDialog<Color>(
  context: context,
  builder: (_) => ItemColorDialog(color: color, iconKey: iconKey),
);

class ItemColorDialog extends StatefulWidget {
  const ItemColorDialog({
    super.key,
    required this.color,
    required this.iconKey,
  });
  final Color color;
  final String iconKey;
  @override
  State<ItemColorDialog> createState() => _ItemColorDialogState();
}

class _ItemColorDialogState extends State<ItemColorDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _hex = TextEditingController(
    text: _format(widget.color),
  );
  late Color _preview = widget.color;
  static String _format(Color color) =>
      '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  static Color? _parse(String? value) {
    final text = (value ?? '').trim().replaceFirst(RegExp(r'^#'), '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(text)) return null;
    return Color(0xff000000 | int.parse(text, radix: 16));
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TroveDialog(
    title: 'Make it your color',
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Preview applies to this item only.'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final preset in ItemPalette.presets)
                OutlinedButton(
                  onPressed: () => setState(() {
                    _preview = preset.accent;
                    _hex.text = _format(preset.accent);
                  }),
                  child: Text(preset.name),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TroveFormRow(
            children: [
              for (final type in ['Quest', 'Award'])
                Column(
                  children: [
                    ItemIcon(
                      iconKey: widget.iconKey,
                      palette: ItemPalette.custom(_preview),
                    ),
                    const SizedBox(height: 8),
                    Text(type, style: TroveTokens.label),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 20),
          TroveTextField(
            label: 'Color · hex',
            controller: _hex,
            helperText: 'Six digits, for example #7654A5.',
            validator: (value) =>
                _parse(value) == null ? 'Enter a six-digit hex color.' : null,
            onChanged: (value) {
              final color = _parse(value);
              if (color != null) setState(() => _preview = color);
            },
          ),
          const SizedBox(height: 20),
          TroveButton(
            label: 'Save color',
            onPressed: () {
              if (_form.currentState!.validate()) {
                Navigator.of(context).pop(_parse(_hex.text));
              }
            },
          ),
          const SizedBox(height: 8),
          TroveButton(
            label: 'Cancel',
            secondary: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    ),
  );
}
