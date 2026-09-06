import 'package:flutter/material.dart';

import 'ui/core/app_shell.dart';

class MinutroveApp extends StatelessWidget {
  const MinutroveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Minutrove',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF38675B)),
        scaffoldBackgroundColor: const Color(0xFFFAF7F0),
        useMaterial3: true,
      ),
      home: const AppShell(),
    );
  }
}
