import 'package:flutter/material.dart';

import 'ui/core/app_shell.dart';
import 'ui/core/tokens.dart';
import 'ui/core/trove_icon.dart';

class MinutroveApp extends StatelessWidget {
  const MinutroveApp({super.key, this.home});

  /// Native composition supplies HomeShell with the shared live repositories.
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    registerTroveAssetLicenses();
    return MaterialApp(
      title: 'Minutrove',
      debugShowCheckedModeBanner: false,
      theme: TroveTokens.theme(),
      home: home ?? const AppShell(),
    );
  }
}
