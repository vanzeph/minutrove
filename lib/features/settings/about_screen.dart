import 'package:flutter/material.dart';

import '../../ui/core/core.dart';

/// About, licensing, notices, local-diagnostics explanation and the in-app
/// help topics for earning, redeeming, consuming, statistics, configuration
/// and backup. No account, cloud service or external link is required.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About & licenses')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(TroveTokens.pagePadding),
          children: [
            Semantics(
              header: true,
              child: Text('Made for your own time', style: TroveTokens.title),
            ),
            const SizedBox(height: 12),
            const Text('Minutrove · v1\nLocal data · iOS & Android'),
            const SizedBox(height: 20),
            TroveButton(
              label: 'Help & how it works',
              onPressed: () => _openHelp(context),
            ),
            const SizedBox(height: 8),
            TroveButton(
              label: 'App license',
              secondary: true,
              onPressed: () => _openLicense(context),
            ),
            const SizedBox(height: 8),
            TroveButton(
              label: 'Dependency & asset notices',
              secondary: true,
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Minutrove',
                applicationVersion: 'v1',
              ),
            ),
            const SizedBox(height: 8),
            TroveButton(
              label: 'Local diagnostics',
              secondary: true,
              onPressed: () => _openDiagnostics(context),
            ),
            const SizedBox(height: 20),
            TroveButton(
              label: 'Back',
              secondary: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openHelp(BuildContext context) => showTroveDialog<void>(
    context: context,
    title: 'Help & how it works',
    builder: (dialogContext) => const _HelpTopics(),
  );

  Future<void> _openLicense(BuildContext context) => showTroveDialog<void>(
    context: context,
    title: 'App license',
    builder: (dialogContext) => const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Minutrove is free software: you can use, study, share and improve '
          'it under the terms of the GNU Affero General Public License 3.0-only.',
        ),
        SizedBox(height: 8),
        Text(
          'The complete license text and source code are published with the '
          'app at github.com/vanzeph/minutrove.',
        ),
      ],
    ),
  );

  Future<void> _openDiagnostics(BuildContext context) => showTroveDialog<void>(
    context: context,
    title: 'Local diagnostics',
    builder: (dialogContext) => const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Minutrove stores your data only on this device. Minimal local '
          'diagnostics may be recorded to explain recovery events.',
        ),
        SizedBox(height: 8),
        Text(
          'Diagnostics contain fixed event codes only. They never include '
          'item names, amounts, identifiers or exported file contents, and '
          'they never leave this device.',
        ),
      ],
    ),
  );
}

class _HelpTopics extends StatelessWidget {
  const _HelpTopics();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _HelpTopic(
        title: 'Earning with a Quest',
        body:
            'Create your own Quest and set its countdown, earning rates and '
            'an optional daily goal. Start a session to earn Coins and Gems '
            'from active time; pausing stops earning, and ending early keeps '
            'what you already earned.',
      ),
      _HelpTopic(
        title: 'Redeeming an Award',
        body:
            'Awards are rewards you define: a pack with a price in Coins, '
            'Gems or both. Redeeming deducts the price and adds the pack’s '
            'time or budget allowance to your Trove balance for that Award.',
      ),
      _HelpTopic(
        title: 'Using an allowance',
        body:
            'Time allowances run like a session and deduct only the time '
            'you actively use. Budget allowances record actual expenses up to '
            'the remaining amount. A tile stays on Home until every allowance '
            'is used.',
      ),
      _HelpTopic(
        title: 'Statistics',
        body:
            'Stats reads the same committed history as your balances. '
            'Daily, weekly, monthly and yearly charts keep minutes, spending, '
            'Coins and Gems in their own units; they are never mixed.',
      ),
      _HelpTopic(
        title: 'Configuring items',
        body:
            'Double tap an item to configure it, or use the explicit '
            'Configure action. Icons, colors and Quest/Award type are '
            'independent. Earning and price edits affect the future only; '
            'history and balances stay unchanged.',
      ),
      _HelpTopic(
        title: 'Backup and restore',
        body:
            'Backups are unencrypted files with your items, balances, '
            'history and settings. Export while no session is running, then '
            'share the file anywhere you like. Restoring checks the whole '
            'file first and replaces this device only after you confirm.',
      ),
    ],
  );
}

class _HelpTopic extends StatelessWidget {
  const _HelpTopic({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: TroveTokens.label),
        const SizedBox(height: 4),
        Text(body),
      ],
    ),
  );
}
