import 'package:flutter/material.dart';

import 'tokens.dart';
import 'trove_icon.dart';

/// Material destinations with an unclamped, measured text-aware height.
class TroveNavigationBar extends StatelessWidget {
  const TroveNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  @override
  Widget build(BuildContext context) {
    final labelHeight = MediaQuery.textScalerOf(context).scale(12) * 1.4;
    return NavigationBar(
      backgroundColor: Colors.white,
      indicatorColor: ItemPalette.presets.first.surface,
      height: 56 + labelHeight,
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      labelTextStyle: WidgetStatePropertyAll(
        TroveTokens.caption.copyWith(color: TroveTokens.ink),
      ),
      destinations: const [
        NavigationDestination(
          icon: TroveIcon('home', size: 24, color: TroveTokens.ink),
          label: 'Home',
        ),
        NavigationDestination(
          icon: TroveIcon('shop', size: 24, color: TroveTokens.ink),
          label: 'Shop',
        ),
        NavigationDestination(
          icon: TroveIcon('stats', size: 24, color: TroveTokens.ink),
          label: 'Stats',
        ),
      ],
    );
  }
}

class CompactSessionBar extends StatelessWidget {
  const CompactSessionBar({
    super.key,
    required this.name,
    required this.timeLabel,
    required this.paused,
    required this.onOpen,
  });
  final String name;
  final String timeLabel;
  final bool paused;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: OutlinedButton(
      onPressed: onOpen,
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        children: [
          Text(name),
          Text('${paused ? 'Paused' : 'Running'} · $timeLabel'),
        ],
      ),
    ),
  );
}
