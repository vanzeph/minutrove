import 'package:flutter/material.dart';

import 'ui/core/tokens.dart';
import 'ui/core/trove_icon.dart';

/// The app chrome. The composition root ([MinutroveStartup]) supplies the
/// live widget tree — onboarding, Home, Shop, Stats and Settings — over the
/// shared SQLite store and platform adapters.
class MinutroveApp extends StatelessWidget {
  const MinutroveApp({super.key, required this.home});

  final Widget home;

  @override
  Widget build(BuildContext context) {
    registerTroveAssetLicenses();
    return MaterialApp(
      title: 'Minutrove',
      debugShowCheckedModeBanner: false,
      theme: TroveTokens.theme(),
      home: home,
    );
  }
}
