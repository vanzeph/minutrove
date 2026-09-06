import 'package:flutter/material.dart';

/// A synthetic, stateless-data smoke surface for the native app foundation.
/// Product features replace these placeholders as their commands become ready.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;

  static const _pages = [
    (
      icon: Icons.home_outlined,
      title: 'A little effort, a little treasure.',
      message: 'Your Quests and owned Awards will appear here.',
    ),
    (
      icon: Icons.storefront_outlined,
      title: 'Make room for what you love.',
      message: 'Your custom Awards will appear in the Shop.',
    ),
    (
      icon: Icons.bar_chart_outlined,
      title: 'See your time add up.',
      message: 'Your activity will appear here when you begin.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final page = _pages[_selectedIndex];
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Minutrove')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                children: [
                  const SizedBox(height: 40),
                  Icon(page.icon, size: 64, color: theme.colorScheme.primary),
                  const SizedBox(height: 24),
                  Semantics(
                    header: true,
                    child: Text(
                      page.title,
                      style: theme.textTheme.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(page.message, textAlign: TextAlign.center),
                  const SizedBox(height: 40),
                  const Text(
                    'Development preview · Sample screens only',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(
            icon: Icon(Icons.storefront_outlined),
            label: 'Shop',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            label: 'Stats',
          ),
        ],
      ),
    );
  }
}
