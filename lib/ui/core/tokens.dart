import 'package:flutter/material.dart';

/// Shared visual values; appearance never encodes an item's behavior.
abstract final class TroveTokens {
  static const paper = Color(0xfff8f7f2);
  static const ink = Color(0xff203b32);
  static const muted = Color(0xff69766f);
  static const line = Color(0xffdde4dd);
  static const primary = Color(0xff23755a);
  static const coin = Color(0xff9a6908);
  static const gem = Color(0xff7654a5);
  static const space8 = 8.0;
  static const space12 = 12.0;
  static const space20 = 20.0;
  static const pagePadding = 24.0;
  static const tileSize = 68.0;
  static const iconSize = 32.0;
  static const tileRadius = 20.0;
  static const modalRadius = 28.0;
  static const controlRadius = 12.0;

  static const title = TextStyle(
    fontSize: 28,
    height: 34 / 28,
    fontWeight: FontWeight.w800,
  );
  static const heading = TextStyle(
    fontSize: 20,
    height: 26 / 20,
    fontWeight: FontWeight.w700,
  );
  static const label = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w700,
  );
  static const caption = TextStyle(
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w600,
  );
  static const small = TextStyle(
    fontSize: 11,
    height: 16 / 11,
    fontWeight: FontWeight.w400,
  );

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(seedColor: primary).copyWith(
      primary: primary,
      onPrimary: Colors.white,
      surface: Colors.white,
      onSurface: ink,
      onSurfaceVariant: muted,
      outlineVariant: line,
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Nunito Sans',
      colorScheme: scheme,
      scaffoldBackgroundColor: paper,
      textTheme: const TextTheme(
        headlineLarge: title,
        titleLarge: heading,
        titleSmall: label,
        bodyLarge: TextStyle(fontSize: 16, height: 1.4),
        bodyMedium: TextStyle(fontSize: 14, height: 20 / 14),
        bodySmall: small,
        labelLarge: label,
        labelMedium: caption,
      ).apply(bodyColor: ink, displayColor: ink),
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: ink,
        titleTextStyle: TextStyle(
          fontFamily: 'Nunito Sans',
          fontSize: 28,
          height: 34 / 28,
          fontWeight: FontWeight.w800,
          color: ink,
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.all(16),
        errorMaxLines: 5,
        helperMaxLines: 5,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 56),
          padding: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(controlRadius),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.all(12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(controlRadius),
          ),
          side: const BorderSide(color: line),
        ),
      ),
    );
  }
}

@immutable
class ItemPalette {
  const ItemPalette(this.name, this.accent, this.surface);
  final String name;
  final Color accent;
  final Color surface;

  static const presets = [
    ItemPalette('Teal', Color(0xff23755a), Color(0xffddf1e6)),
    ItemPalette('Plum', Color(0xff7654a5), Color(0xffeee8f6)),
    ItemPalette('Blue', Color(0xff3265a6), Color(0xffe4edf8)),
    ItemPalette('Coral', Color(0xffb94e2c), Color(0xfffce8d8)),
  ];

  /// Custom colors tint the surface; text always retains the shared ink color.
  factory ItemPalette.custom(Color color) => ItemPalette(
    'Custom',
    color.withValues(alpha: 1),
    Color.lerp(Colors.white, color.withValues(alpha: 1), .14)!,
  );

  /// Preserve the chosen accent and use a contrasting neutral when needed.
  Color get iconBackground {
    final luminance = accent.computeLuminance();
    double ratio(Color background) {
      final other = background.computeLuminance();
      return (luminance > other)
          ? (luminance + .05) / (other + .05)
          : (other + .05) / (luminance + .05);
    }

    if (ratio(surface) >= 3) return surface;
    return ratio(Colors.white) >= ratio(TroveTokens.ink)
        ? Colors.white
        : TroveTokens.ink;
  }
}
