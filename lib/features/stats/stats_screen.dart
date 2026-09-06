import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import 'stats_chart.dart';
import 'stats_filters.dart';
import 'stats_model.dart';
import 'stats_source.dart';

/// A HomeRoutes.stats body. The parent shell retains wallet/session navigation.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.source});
  final StatsSource source;
  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> with WidgetsBindingObserver {
  StreamSubscription<StatsContext>? _subscription;
  Timer? _dayTimer;
  StatsContext? _context;
  StatsSelection _selection = const StatsSelection();
  final _anchors = <StatsPeriod, DayKey>{};
  List<List<StatsBucket>>? _charts;
  String? _error;
  bool _loading = true;
  StatsSelection _loadedSelection = const StatsSelection();
  Map<StatsPeriod, DayKey> _loadedAnchors = {};
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscribe();
    _dayTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refresh(onlyIfDayChanged: true),
    );
  }

  void _subscribe() {
    _subscription = widget.source.watchContext().listen(
      _acceptContext,
      onError: (Object _) => _failed(
        'Could not read activity. Your data has not changed. Try again.',
      ),
    );
  }

  @override
  void didUpdateWidget(StatsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _subscription?.cancel();
      _generation++;
      _context = null;
      _charts = null;
      _anchors.clear();
      _subscribe();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _subscription?.cancel();
    _dayTimer?.cancel();
    super.dispose();
  }

  void _failed(String message) {
    if (!mounted) return;
    _generation++;
    setState(() {
      _error = message;
      _charts = null;
    });
  }

  void _acceptContext(StatsContext data) {
    if (!mounted) return;
    final previous = _context;
    for (final period in StatsPeriod.values) {
      if (_anchors[period] == null ||
          (previous != null &&
              periodStart(period, _anchors[period]!) ==
                  periodStart(period, previous.today))) {
        _anchors[period] = data.today;
      }
    }
    if (_selection.category == StatsCategory.item &&
        _selection.item(data) == null) {
      _selection = StatsSelection(
        metric: _selection.metric,
        graph: _selection.graph,
      );
    }
    _context = data;
    _selection = _selection.normalized(data);
    _load();
  }

  Future<void> _refresh({bool onlyIfDayChanged = false}) async {
    final source = widget.source;
    final generation = _generation;
    try {
      final result = await source.refreshContext();
      if (!mounted || source != widget.source || generation != _generation) {
        return;
      }
      switch (result) {
        case Success(:final value):
          if (!onlyIfDayChanged ||
              _context?.today != value.today ||
              _context?.zone != value.zone) {
            _acceptContext(value);
          }
        case Failure():
          if (!onlyIfDayChanged) _failed('Could not read activity. Try again.');
      }
    } catch (_) {
      if (mounted && generation == _generation && !onlyIfDayChanged) {
        _failed('Could not read activity. Try again.');
      }
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final selection = _selection;
    final anchors = Map<StatsPeriod, DayKey>.of(_anchors);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.source.load([
        for (final period in StatsPeriod.values)
          selection.query(period, anchors[period]!),
      ]);
      if (!mounted || generation != _generation) return;
      switch (result) {
        case Success(:final value):
          if (value.length != StatsPeriod.values.length) {
            _failed('Could not read all four periods. Try again.');
          } else {
            setState(() {
              _charts = value;
              _loading = false;
              _loadedSelection = selection;
              _loadedAnchors = anchors;
            });
          }
        case Failure(:final error):
          _failed(
            error is NumericOverflow
                ? 'This period is too large to display. Choose another date or a single item.'
                : 'Could not read activity for these filters. Try again or change filters.',
          );
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        _failed('Could not read activity. Try again.');
      }
    }
  }

  Future<void> _filters() async {
    final data = _context;
    if (data == null) return;
    final result = await showStatsFilters(context, data, _selection);
    if (!mounted || result == null) return;
    _selection = result;
    _acceptContext(_context!);
  }

  Future<void> _navigate(StatsPeriod period, DayKey day) async {
    _anchors[period] = day;
    await _load();
  }

  Future<void> _current(StatsPeriod period) async {
    // Refresh the reporting date first, including after manual wall-clock edits.
    final generation = _generation;
    try {
      final result = await widget.source.refreshContext();
      if (!mounted || generation != _generation) return;
      switch (result) {
        case Success(:final value):
          _anchors[period] = value.today;
          _acceptContext(value);
        case Failure():
          _failed('Could not determine the current reporting date. Try again.');
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        _failed('Could not determine the current reporting date. Try again.');
      }
    }
  }

  Future<void> _chooseDate(StatsPeriod period) async {
    final selected = await showDatePicker(
      context: context,
      helpText: 'Choose ${periodName(period).toLowerCase()} date',
      initialDate: statsDate(_anchors[period]!),
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
    );
    if (mounted && selected != null) _navigate(period, statsDay(selected));
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: _refresh,
    child: ListView(
      key: const PageStorageKey('stats-scroll'),
      padding: const EdgeInsets.all(TroveTokens.pagePadding),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Semantics(
          header: true,
          child: Text(
            'Your progress',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
        ),
        const SizedBox(height: 16),
        if (_context case final data?) ...[
          TroveButton(
            label:
                'Filters: ${_selection.label(data)} · ${metricName(_selection.metric)}',
            secondary: true,
            onPressed: _filters,
          ),
          const SizedBox(height: 8),
          TroveFormRow(
            children: [
              for (final graph in StatsGraph.values)
                Semantics(
                  selected: _selection.graph == graph,
                  child: TroveButton(
                    label: graph == StatsGraph.bars ? 'Bars' : 'Lines',
                    secondary: _selection.graph != graph,
                    onPressed: () => setState(
                      () => _selection = StatsSelection(
                        category: _selection.category,
                        itemId: _selection.itemId,
                        metric: _selection.metric,
                        currency: _selection.currency,
                        graph: graph,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Committed activity · ${statsUnit(_selection.metric, _selection.currency)}\nReporting date: ${statsDateLabel(statsDate(data.today))} · ${data.zone.ianaName}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
        ],
        if (_error case final error?) ...[
          Semantics(liveRegion: true, child: Text(error)),
          const SizedBox(height: 12),
          TroveButton(label: 'Retry', onPressed: _refresh),
        ],
        SizedBox(
          height: 4,
          child: _loading && _error == null
              ? const LinearProgressIndicator(
                  semanticsLabel: 'Loading all four periods',
                )
              : null,
        ),
        if (_charts case final charts?)
          for (var i = 0; i < StatsPeriod.values.length; i++) ...[
            Visibility(
              key: ValueKey('chart-slot-${StatsPeriod.values[i].name}'),
              visible: !_loading,
              maintainState: true,
              maintainAnimation: true,
              maintainSize: true,
              child: StatsChart(
                period: StatsPeriod.values[i],
                anchor: _loadedAnchors[StatsPeriod.values[i]]!,
                selection: StatsSelection(
                  category: _loadedSelection.category,
                  itemId: _loadedSelection.itemId,
                  metric: _loadedSelection.metric,
                  currency: _loadedSelection.currency,
                  graph: _selection.graph,
                ),
                buckets: charts[i],
                onPrevious:
                    shiftPeriod(
                          StatsPeriod.values[i],
                          _anchors[StatsPeriod.values[i]]!,
                          -1,
                        ) ==
                        null
                    ? null
                    : () => _navigate(
                        StatsPeriod.values[i],
                        shiftPeriod(
                          StatsPeriod.values[i],
                          _anchors[StatsPeriod.values[i]]!,
                          -1,
                        )!,
                      ),
                onNext:
                    shiftPeriod(
                          StatsPeriod.values[i],
                          _anchors[StatsPeriod.values[i]]!,
                          1,
                        ) ==
                        null
                    ? null
                    : () => _navigate(
                        StatsPeriod.values[i],
                        shiftPeriod(
                          StatsPeriod.values[i],
                          _anchors[StatsPeriod.values[i]]!,
                          1,
                        )!,
                      ),
                onCurrent: () => _current(StatsPeriod.values[i]),
                onChooseDate: () => _chooseDate(StatsPeriod.values[i]),
              ),
            ),
            const SizedBox(height: 16),
          ],
        if (_charts != null)
          const Text(
            'Keep showing up. Every minute counts.',
            style: TroveTokens.caption,
          ),
      ],
    ),
  );
}
