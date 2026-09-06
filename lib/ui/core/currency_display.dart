import 'package:flutter/material.dart';

import 'tokens.dart';
import 'trove_icon.dart';

/// Exact integer formatting; never round a spendable balance via double.
String formatMillionths(int amount) {
  if (amount < 0) {
    throw ArgumentError.value(amount, 'amount', 'Must not be negative');
  }
  final whole = amount ~/ 1000000;
  final remainder = amount % 1000000;
  if (remainder == 0) return '$whole';
  final fraction = remainder
      .toString()
      .padLeft(6, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '$whole.$fraction';
}

enum TroveCurrency { coins, gems }

class CurrencyDisplay extends StatelessWidget {
  const CurrencyDisplay({
    super.key,
    required this.currency,
    required this.millionths,
  });
  final TroveCurrency currency;
  final int millionths;
  @override
  Widget build(BuildContext context) {
    final coins = currency == TroveCurrency.coins;
    final label = '${formatMillionths(millionths)} ${coins ? 'Coins' : 'Gems'}';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TroveIcon(coins ? 'coin' : 'gem', size: 24),
          Text(
            label,
            style: TroveTokens.label.copyWith(
              color: coins ? TroveTokens.coin : TroveTokens.gem,
            ),
          ),
        ],
      ),
    );
  }
}

class WalletDisplay extends StatelessWidget {
  const WalletDisplay({super.key, required this.coins, required this.gems});
  final int coins;
  final int gems;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: 24,
        runSpacing: 12,
        alignment: WrapAlignment.spaceBetween,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: CurrencyDisplay(
              currency: TroveCurrency.coins,
              millionths: coins,
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: CurrencyDisplay(
              currency: TroveCurrency.gems,
              millionths: gems,
            ),
          ),
        ],
      ),
    ),
  );
}
