import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import 'stats_model.dart';

Future<StatsSelection?> showStatsFilters(
  BuildContext context,
  StatsContext data,
  StatsSelection selection,
) => showDialog<StatsSelection>(
  context: context,
  builder: (_) => _StatsFilters(data: data, initial: selection),
);

class _StatsFilters extends StatefulWidget {
  const _StatsFilters({required this.data, required this.initial});
  final StatsContext data;
  final StatsSelection initial;
  @override
  State<_StatsFilters> createState() => _StatsFiltersState();
}

class _StatsFiltersState extends State<_StatsFilters> {
  late StatsSelection selection = widget.initial;
  void choose({
    StatsCategory? category,
    ItemId? item,
    StatsMetric? metric,
    BudgetCurrency? currency,
    StatsGraph? graph,
  }) => setState(() {
    selection = StatsSelection(
      category: category ?? selection.category,
      itemId: category != null ? item : selection.itemId,
      metric: metric ?? selection.metric,
      currency: currency ?? selection.currency,
      graph: graph ?? selection.graph,
    ).normalized(widget.data);
  });

  @override
  Widget build(BuildContext context) => TroveDialog(
    title: 'See your progress',
    actions: [
      TroveButton(
        label: 'Apply filters',
        onPressed: () => Navigator.pop(context, selection),
      ),
      TroveButton(
        label: 'Cancel',
        secondary: true,
        onPressed: () => Navigator.pop(context),
      ),
    ],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Choose a measure with one consistent unit.'),
        const SizedBox(height: 16),
        const Text('Items', style: TroveTokens.label),
        const SizedBox(height: 8),
        TroveButton(
          label: selection.label(widget.data),
          secondary: true,
          onPressed: () async {
            final result = await _chooseItems(context, widget.data, selection);
            if (result != null && mounted) {
              choose(category: result.$1, item: result.$2);
            }
          },
        ),
        const SizedBox(height: 16),
        const Text('Metric', style: TroveTokens.label),
        for (final metric in StatsMetric.values) ...[
          const SizedBox(height: 8),
          Semantics(
            selected: selection.metric == metric,
            child: TroveButton(
              label:
                  '${selection.metric == metric ? 'Selected: ' : ''}${metricName(metric)}',
              secondary: selection.metric != metric,
              onPressed: selection.unavailable(metric, widget.data) == null
                  ? () => choose(metric: metric)
                  : null,
            ),
          ),
          if (selection.unavailable(metric, widget.data) case final reason?)
            Text(reason, style: Theme.of(context).textTheme.bodySmall),
        ],
        if (selection.metric == StatsMetric.budgetSpent) ...[
          const SizedBox(height: 16),
          const Text('Budget currency', style: TroveTokens.label),
          const Text('Each currency is shown separately.'),
          for (final currency in selection.currencies(widget.data))
            Semantics(
              selected: selection.currency == currency,
              child: TroveButton(
                label:
                    '${selection.currency == currency ? 'Selected: ' : ''}${currency.code}',
                secondary: selection.currency != currency,
                onPressed: () => choose(currency: currency),
              ),
            ),
        ],
        const SizedBox(height: 16),
        const Text('Graph', style: TroveTokens.label),
        TroveFormRow(
          children: [
            for (final graph in StatsGraph.values)
              Semantics(
                selected: selection.graph == graph,
                child: TroveButton(
                  label: graph == StatsGraph.bars ? 'Bars' : 'Lines',
                  secondary: selection.graph != graph,
                  onPressed: () => choose(graph: graph),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}

Future<(StatsCategory, ItemId?)?> _chooseItems(
  BuildContext context,
  StatsContext data,
  StatsSelection selection,
) => showDialog<(StatsCategory, ItemId?)>(
  context: context,
  builder: (_) => _ItemChoices(data: data, selection: selection),
);

class _ItemChoices extends StatefulWidget {
  const _ItemChoices({required this.data, required this.selection});
  final StatsContext data;
  final StatsSelection selection;
  @override
  State<_ItemChoices> createState() => _ItemChoicesState();
}

class _ItemChoicesState extends State<_ItemChoices> {
  String search = '';
  @override
  Widget build(BuildContext context) {
    final items =
        widget.data.items
            .where(
              (item) =>
                  itemLabel(item).toLowerCase().contains(search.toLowerCase()),
            )
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    final categories = StatsCategory.values
        .where(
          (c) =>
              c != StatsCategory.item &&
              categoryName(c).toLowerCase().contains(search.toLowerCase()),
        )
        .toList();
    return Dialog(
      child: SizedBox(
        width: 480,
        height: MediaQuery.sizeOf(context).height * .7,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(
                'Choose items',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(labelText: 'Search items'),
                onChanged: (value) => setState(() => search = value),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: items.isEmpty && categories.isEmpty
                    ? const Center(child: Text('No matching items.'))
                    : ListView.builder(
                        itemCount: categories.length + items.length,
                        itemBuilder: (context, index) {
                          final category = index < categories.length
                              ? categories[index]
                              : StatsCategory.item;
                          final item = index < categories.length
                              ? null
                              : items[index - categories.length];
                          final selected =
                              widget.selection.category == category &&
                              widget.selection.itemId == item?.id;
                          return Semantics(
                            selected: selected,
                            child: ListTile(
                              title: Text(
                                item == null
                                    ? categoryName(category)
                                    : itemLabel(item),
                              ),
                              subtitle: item == null
                                  ? null
                                  : Text(
                                      item.type == ItemType.quest
                                          ? 'Quest'
                                          : 'Award',
                                    ),
                              selected: selected,
                              onTap: () =>
                                  Navigator.pop(context, (category, item?.id)),
                            ),
                          );
                        },
                      ),
              ),
              TroveButton(
                label: 'Cancel',
                secondary: true,
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
