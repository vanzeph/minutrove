import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'icon_catalog.dart';
import 'tokens.dart';

/// Render exact bundled SVGs; never fetch appearance assets over the network.
class TroveIcon extends StatelessWidget {
  const TroveIcon(
    this.iconKey, {
    super.key,
    this.color,
    this.size = 32,
    this.semanticLabel,
  });
  final String iconKey;
  final Color? color;
  final double size;
  final String? semanticLabel;

  static const _systemKeys = {
    'coin',
    'gem',
    'home',
    'shop',
    'stats',
    'close',
    'plus',
    'settings',
  };

  @override
  Widget build(BuildContext context) {
    final known =
        IconCatalog.find(iconKey) != null || _systemKeys.contains(iconKey);
    return SvgPicture.asset(
      'assets/icons/${known ? iconKey : 'puzzle'}.svg',
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticsLabel: semanticLabel,
      excludeFromSemantics: semanticLabel == null,
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color!, BlendMode.srcIn),
    );
  }
}

class ItemIcon extends StatelessWidget {
  const ItemIcon({super.key, required this.iconKey, required this.palette});
  final String iconKey;
  final ItemPalette palette;

  @override
  Widget build(BuildContext context) => Container(
    width: TroveTokens.tileSize,
    height: TroveTokens.tileSize,
    decoration: BoxDecoration(
      color: palette.iconBackground,
      borderRadius: BorderRadius.circular(TroveTokens.tileRadius),
    ),
    alignment: Alignment.center,
    child: TroveIcon(iconKey, color: palette.accent),
  );
}

bool _licensesRegistered = false;

/// Call once before exposing Flutter's showLicensePage/About flow.
void registerTroveAssetLicenses() {
  if (_licensesRegistered) return;
  _licensesRegistered = true;
  LicenseRegistry.addLicense(() async* {
    for (final entry in const {
      'Nunito Sans': 'NUNITO_SANS_OFL.txt',
      'Lucide icons': 'LUCIDE_LICENSE.txt',
      'Minutrove original design icons': 'MINUTROVE_LICENSE.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        entry.key,
      ], await rootBundle.loadString('assets/licenses/${entry.value}'));
    }
  });
}
