import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import '../home/home_data.dart';
import 'purchase_controller.dart';

String shopAllowance(Milliseconds? time, BudgetAmount? budget) => [
  if (time != null) homeDuration(time.value),
  if (budget != null) '$budget budget',
].join(' + ');

Future<EconomicState?> showRedemptionDialog({
  required BuildContext context,
  required ItemId awardId,
  required Stream<HomeData> Function() watchShop,
  required EconomyRepository economy,
  OperationId Function()? newOperationId,
}) => showDialog<EconomicState>(
  context: context,
  barrierDismissible: false,
  builder: (_) => RedemptionDialog(
    awardId: awardId,
    watchShop: watchShop,
    economy: economy,
    newOperationId: newOperationId,
  ),
);

class RedemptionDialog extends StatefulWidget {
  const RedemptionDialog({
    super.key,
    required this.awardId,
    required this.watchShop,
    required this.economy,
    this.newOperationId,
  });
  final ItemId awardId;
  final Stream<HomeData> Function() watchShop;
  final EconomyRepository economy;
  final OperationId Function()? newOperationId;

  @override
  State<RedemptionDialog> createState() => _RedemptionDialogState();
}

class _RedemptionDialogState extends State<RedemptionDialog> {
  late final PurchaseController _purchase = PurchaseController(
    awardId: widget.awardId,
    watchShop: widget.watchShop,
    economy: widget.economy,
    newOperationId: widget.newOperationId,
  )..addListener(_changed);
  final _text = TextEditingController(text: '1');
  bool _closing = false;

  void _changed() {
    if (!mounted) return;
    if (_text.text != _purchase.input) {
      _text.value = TextEditingValue(
        text: _purchase.input,
        selection: TextSelection.collapsed(offset: _purchase.input.length),
      );
    }
    if (_purchase.completed != null && !_closing) {
      _closing = true;
      // Rebuild PopScope before closing after an in-flight submission.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, _purchase.completed);
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    _purchase.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _purchase;
    final summary = p.summary;
    final config = p.item?.configuration;
    final displayedRevision = p.item?.revision;
    final displayedQuantity = p.quantity;
    final editable = !p.locked && p.available;
    return PopScope(
      canPop: !p.busy,
      child: IgnorePointer(
        ignoring: p.busy,
        child: TroveDialog(
          title: 'Redeem ${p.item?.name ?? 'Award'}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (p.readFailed) ...[
                const Text('Could not load the current offer and wallet.'),
                TroveButton(label: 'Retry loading', onPressed: p.reload),
              ] else if (p.data == null)
                const Center(child: CircularProgressIndicator())
              else if (!p.available)
                const Text('This Award is no longer available for purchase.')
              else if (config is AwardConfiguration) ...[
                Text(
                  '1 ${config.packName} = '
                  '${shopAllowance(config.timeGrant, config.budgetGrant)}',
                  style: Theme.of(context).textTheme.bodyMedium!
                      .copyWith(color: TroveTokens.muted),
                ),
                const SizedBox(height: 8),
                ShopCurrencies(amounts: config.price),
                const SizedBox(height: 16),
                if (p.changed) ...[
                  Semantics(
                    liveRegion: true,
                    child: const Text(
                      'Review the new price and allowance. This Award changed '
                      'while the purchase was open.',
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Text('Quantity · whole packs', style: TroveTokens.label),
                const SizedBox(height: 8),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: TroveTokens.paper,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Decrease quantity',
                        onPressed: editable && p.quantity > 1
                            ? () => p.selectQuantity(p.quantity - 1)
                            : null,
                        icon: const Text('−', style: TroveTokens.heading),
                      ),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('purchase-quantity'),
                          controller: _text,
                          enabled: editable,
                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,
                          onChanged: p.setInput,
                          decoration: const InputDecoration(
                            hintText: 'Packs',
                            semanticCounterText: 'Quantity in whole packs',
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Increase quantity',
                        onPressed:
                            editable &&
                                p.quantity < (summary?.maximumPurchasable ?? 0)
                            ? () => p.selectQuantity(p.quantity + 1)
                            : null,
                        icon: const TroveIcon('plus', size: 24),
                      ),
                    ],
                  ),
                ),
                if (!p.validInput)
                  Semantics(
                    liveRegion: true,
                    child: const Text(
                      'Enter a positive whole number of packs.',
                    ),
                  ),
                if (summary != null) ...[
                  _QuantitySlider(
                    quantity: p.quantity,
                    maximum: math.max(
                      p.quantity,
                      math.max(1, summary.maximumPurchasable),
                    ),
                    enabled: editable,
                    onChanged: p.selectQuantity,
                  ),
                  Text(
                    'Max affordable: ${summary.maximumAffordable} packs',
                    style: TroveTokens.caption,
                  ),
                  if (summary.maximumPurchasable < summary.maximumAffordable)
                    Text(
                      'Allowance capacity: ${summary.maximumPurchasable} packs',
                      style: TroveTokens.caption,
                    ),
                  const SizedBox(height: 16),
                  Container(
                    key: const ValueKey('purchase-summary'),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: ItemPalette.presets[3].surface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!summary.overflow)
                          Text(
                            'You get: ${shopAllowance(summary.time, summary.budget)}',
                            style: TroveTokens.label,
                          ),
                        if (summary.total case final total?) ...[
                          const SizedBox(height: 12),
                          const Text('Total'),
                          ShopCurrencies(amounts: total),
                        ],
                        const SizedBox(height: 12),
                        const Text('Wallet now'),
                        ShopCurrencies(amounts: p.data!.wallet.balances),
                        if (summary.after case final after?) ...[
                          const SizedBox(height: 12),
                          const Text('After purchase'),
                          ShopCurrencies(amounts: after),
                        ],
                        if (summary.overflow)
                          const Text(
                            'This quantity exceeds the supported price or '
                            'allowance limit. Choose fewer packs.',
                          ),
                        if (summary.missingCoins > 0)
                          Text(
                            'You need ${formatMillionths(summary.missingCoins)} more ${summary.missingCoins == 1000000 ? 'Coin' : 'Coins'}.',
                          ),
                        if (summary.missingGems > 0)
                          Text(
                            'You need ${formatMillionths(summary.missingGems)} more ${summary.missingGems == 1000000 ? 'Gem' : 'Gems'}.',
                          ),
                      ],
                    ),
                  ),
                  if (summary.maximumPurchasable > 0 &&
                      p.quantity > summary.maximumPurchasable) ...[
                    const SizedBox(height: 8),
                    TroveButton(
                      label:
                          'Use affordable quantity · ${summary.maximumPurchasable}',
                      secondary: true,
                      onPressed: editable
                          ? () => p.selectQuantity(summary.maximumPurchasable)
                          : null,
                    ),
                  ],
                  if (!summary.overflow) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Added to this Award in My Trove.\n'
                      'New balance: ${shopAllowance(summary.pooledTime, summary.pooledBudget)}.',
                      style: TroveTokens.caption,
                    ),
                  ],
                ],
              ],
              if (p.error != null) ...[
                const SizedBox(height: 16),
                Semantics(liveRegion: true, child: Text(p.error!)),
              ],
              const SizedBox(height: 16),
              TroveButton(
                key: const ValueKey('purchase-submit'),
                label: p.busy
                    ? 'Purchasing…'
                    : p.retrying
                    ? 'Retry purchase'
                    : p.changed
                    ? 'Confirm updated purchase'
                    : 'Redeem ${p.quantity} ${p.quantity == 1 ? 'pack' : 'packs'}',
                onPressed: p.canSubmit
                    ? () => p.submit(
                        displayedRevision: displayedRevision,
                        displayedQuantity: displayedQuantity,
                      )
                    : null,
              ),
              const SizedBox(height: 8),
              TroveButton(
                label: 'Cancel',
                secondary: true,
                onPressed: p.busy ? null : () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ShopCurrencies extends StatelessWidget {
  const ShopCurrencies({super.key, required this.amounts});
  final CurrencyAmounts amounts;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 16,
    runSpacing: 8,
    children: [
      CurrencyDisplay(
        currency: TroveCurrency.coins,
        millionths: amounts.coins.units,
      ),
      CurrencyDisplay(
        currency: TroveCurrency.gems,
        millionths: amounts.gems.units,
      ),
    ],
  );
}

/// Slider uses normalized geometry only. Integer endpoints and direct entry
/// remain exact even when quantities exceed double's integer precision.
class _QuantitySlider extends StatelessWidget {
  const _QuantitySlider({
    required this.quantity,
    required this.maximum,
    required this.enabled,
    required this.onChanged,
  });
  final int quantity;
  final int maximum;
  final bool enabled;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Slider(
    key: const ValueKey('purchase-slider'),
    value: maximum <= 1 ? 0 : (quantity - 1) / (maximum - 1),
    divisions: maximum > 1 && maximum <= 1000 ? maximum - 1 : null,
    label: '$quantity packs',
    semanticFormatterCallback: (_) => '$quantity packs',
    onChanged: enabled && maximum > 1
        ? (value) {
            if (value <= 0) return onChanged(1);
            if (value >= 1) return onChanged(maximum);
            final scaled = (value * 1000000).round();
            onChanged(
              1 +
                  ((BigInt.from(maximum - 1) * BigInt.from(scaled) +
                              BigInt.from(500000)) ~/
                          BigInt.from(1000000))
                      .toInt(),
            );
          }
        : null,
  );
}
