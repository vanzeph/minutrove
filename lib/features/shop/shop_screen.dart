import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import '../home/home_data.dart';
import '../items/items.dart';
import 'redemption_dialog.dart';

/// Content for HomeRoutes.shop. HomeShell owns the wallet and active timer.
class ShopScreen extends StatefulWidget {
  const ShopScreen({
    super.key,
    required this.watchShop,
    required this.economy,
    required this.editing,
  });
  final Stream<HomeData> Function() watchShop;
  final EconomyRepository economy;
  final ItemEditing editing;

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> {
  late Stream<HomeData> _stream = _watch();
  bool _routing = false;
  String? _error;

  Stream<HomeData> _watch() async* {
    yield* widget.watchShop();
  }

  @override
  void didUpdateWidget(ShopScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.watchShop != oldWidget.watchShop) _stream = _watch();
  }

  Future<void> _open(Item? item, {bool configure = false}) async {
    if (_routing) return;
    setState(() {
      _routing = true;
      _error = null;
    });
    try {
      if (item == null || configure) {
        await showItemEditor(
          context: context,
          editing: widget.editing,
          item: item,
        );
      } else {
        final result = await showRedemptionDialog(
          context: context,
          awardId: item.id,
          watchShop: widget.watchShop,
          economy: widget.economy,
          newOperationId: widget.editing.operationId,
        );
        if (result != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${item.name} added to My Trove.')),
          );
        }
      }
    } catch (_) {
      if (mounted) _error = 'Could not open this Award. Try again.';
    } finally {
      if (mounted) setState(() => _routing = false);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<HomeData>(
    stream: _stream,
    builder: (context, snapshot) {
      final failed =
          snapshot.hasError || snapshot.connectionState == ConnectionState.done;
      final data = snapshot.data;
      final ready = !failed && data != null;
      final offers = ready
          ? (data.items
                .where((i) => !i.archived && i.type == ItemType.award)
                .toList()
              ..sort((a, b) {
                final order = a.order.compareTo(b.order);
                return order == 0 ? a.id.value.compareTo(b.id.value) : order;
              }))
          : <Item>[];
      return ListView(
        key: const PageStorageKey('shop-scroll'),
        padding: const EdgeInsets.all(24),
        children: [
          Text('Reward Shop', style: TroveTokens.title),
          const SizedBox(height: 12),
          const Text('Turn your effort into something good.'),
          if (_error != null) Text(_error!),
          const SizedBox(height: 20),
          if (failed) ...[
            const Text('Could not load the catalog and balances.'),
            TroveButton(
              label: 'Retry loading Shop',
              onPressed: () => setState(() => _stream = _watch()),
            ),
          ] else if (data == null)
            const Center(child: CircularProgressIndicator())
          else if (offers.isEmpty) ...[
            Text('Your next reward starts here.', style: TroveTokens.heading),
            const SizedBox(height: 12),
            const Text(
              'Add an Award with a pack price and time or budget allowance.',
            ),
          ],
          for (final item in offers) ...[
            _OfferCard(
              item: item,
              onRedeem: _routing ? null : () => _open(item),
              onConfigure: _routing ? null : () => _open(item, configure: true),
            ),
            const SizedBox(height: 20),
          ],
          if (ready)
            TroveButton(
              label: 'Add item',
              secondary: true,
              onPressed: _routing ? null : () => _open(null),
            ),
        ],
      );
    },
  );
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.item,
    required this.onRedeem,
    required this.onConfigure,
  });
  final Item item;
  final VoidCallback? onRedeem;
  final VoidCallback? onConfigure;
  @override
  Widget build(BuildContext context) {
    final config = item.configuration as AwardConfiguration;
    return Container(
      key: ValueKey('shop-offer-${item.id.value}'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final icon = ItemIcon(
            iconKey: item.iconKey,
            palette: ItemPalette.custom(Color(item.colorArgb)),
          );
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(item.name, style: TroveTokens.heading),
              const SizedBox(height: 4),
              Text(
                'Award · ${shopAllowance(config.timeGrant, config.budgetGrant)} per ${config.packName}',
              ),
              const SizedBox(height: 8),
              ShopCurrencies(amounts: config.price),
              const SizedBox(height: 12),
              TroveButton(label: 'Redeem ${item.name}', onPressed: onRedeem),
              TextButton(
                onPressed: onConfigure,
                child: Text(
                  'Configure ${item.name}',
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          );
          if (constraints.maxWidth < 280 ||
              MediaQuery.textScalerOf(context).scale(14) > 20) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(alignment: Alignment.centerLeft, child: icon),
                const SizedBox(height: 12),
                details,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              icon,
              const SizedBox(width: 16),
              Expanded(child: details),
            ],
          );
        },
      ),
    );
  }
}
