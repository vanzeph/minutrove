import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import 'item_draft.dart';
import 'item_editing.dart';

Future<Item?> showItemEditor({
  required BuildContext context,
  required ItemEditing editing,
  Item? item,
}) => showDialog<Item>(
  context: context,
  barrierDismissible: false,
  builder: (_) => ItemEditor(editing: editing, item: item),
);

class ItemEditor extends StatefulWidget {
  const ItemEditor({super.key, required this.editing, this.item});
  final ItemEditing editing;
  final Item? item;
  @override
  State<ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<ItemEditor> {
  late ItemDraft _draft;
  late Future<Result<ItemEditFacts>> _facts;
  late final Stream<List<Group>> _groups = widget.editing.repository
      .watchGroups();
  final _form = GlobalKey<FormState>();
  final _fields = <String, TextEditingController>{};
  bool _busy = false;
  DomainError? _error;
  OperationId? _operation;
  Item? _saved;
  String? _receipt;

  @override
  void initState() {
    super.initState();
    _initialize(widget.item);
  }

  void _initialize(Item? item) {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    _fields.clear();
    _draft = ItemDraft(
      id: item?.id ?? ItemId(widget.editing.newUuid()),
      item: item,
    );
    _facts = item == null
        ? Future.value(
            const Success(ItemEditFacts(hasHistory: false, active: false)),
          )
        : widget.editing.readFacts(item.id);
    _operation = null;
    _error = null;
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _changed(VoidCallback change) => setState(() {
    change();
    _operation = null;
    _error = null;
  });

  Widget _field(
    String label,
    String value,
    ValueChanged<String> change, {
    bool numeric = false,
    bool enabled = true,
    String? Function(String?)? validator,
  }) {
    final controller = _fields.putIfAbsent(
      label,
      () => TextEditingController(text: value),
    );
    return TroveTextField(
      key: ValueKey(label),
      label: label,
      controller: controller,
      enabled: enabled,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : null,
      onChanged: (value) => _changed(() => change(value)),
      validator: validator,
    );
  }

  String? _required(String? value) =>
      (value ?? '').trim().isEmpty ? 'Enter a value.' : null;
  String? _amount(String? value) {
    try {
      MicroAmount.parse((value ?? '').trim());
      return null;
    } on DomainError {
      return 'Use a non-negative number with at most 6 decimals.';
    }
  }

  Widget _money(String label, String value, ValueChanged<String> change) =>
      _field(label, value, change, numeric: true, validator: _amount);

  Widget _duration(
    String label,
    String value,
    TimeUnit unit,
    ValueChanged<String> change,
    ValueChanged<TimeUnit> changeUnit,
  ) => TroveFormRow(
    children: [
      _field(
        label,
        value,
        change,
        numeric: true,
        validator: (text) {
          try {
            Milliseconds.parseConfiguration((text ?? '').trim(), unit: unit);
            return null;
          } on DomainError {
            return 'Enter a bounded positive duration in whole seconds.';
          }
        },
      ),
      _choice('$label unit', unit, {
        for (final u in TimeUnit.values) u: u.name,
      }, changeUnit),
    ],
  );

  Widget _choice<T>(
    String label,
    T value,
    Map<T, String> options,
    ValueChanged<T> change, {
    bool enabled = true,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      // A popup button can grow with wrapped text; fixed-height dropdowns clip
      // at 200% text on a 320-wide phone.
      PopupMenuButton<T>(
        enabled: enabled,
        tooltip: label,
        initialValue: value,
        onSelected: (v) => _changed(() => change(v)),
        itemBuilder: (_) => [
          for (final entry in options.entries)
            PopupMenuItem(value: entry.key, child: Text(entry.value)),
        ],
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border.all(color: TroveTokens.line),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${options[value] ?? 'Unavailable group'}${enabled ? '' : ' · locked'}',
                ),
              ),
              if (enabled) const Icon(Icons.arrow_drop_down, size: 24),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _toggle(
    String label,
    bool value,
    ValueChanged<bool> change, {
    bool enabled = true,
  }) => CheckboxListTile(
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
    title: Text(label),
    value: value,
    onChanged: enabled ? (v) => _changed(() => change(v!)) : null,
  );

  Future<void> _save({bool restore = false}) async {
    FocusScope.of(context).unfocus();
    if (!_form.currentState!.validate()) return;
    final Item proposed;
    try {
      proposed = _draft.build(
        widget.editing.currencies,
        archived: restore ? false : null,
      );
    } on DomainError catch (error) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.editing.repository.saveItem(
      operationId: _operation ??= widget.editing.operationId(),
      item: proposed,
      expectedRevision: _draft.original?.revision,
    );
    if (!mounted) return;
    if (result is Failure<Item>) {
      setState(() {
        _busy = false;
        _error = result.error;
      });
      return;
    }
    _saved = (result as Success<Item>).value;
    await _readReceipt();
  }

  Future<void> _readReceipt() async {
    setState(() => _busy = true);
    final saved = _saved!;
    var receipt = saved.archived
        ? 'Archived. History and usable Trove allowances are retained.'
        : 'Saved. Appearance and group apply immediately.';
    if (saved.configuration is QuestConfiguration) {
      final facts = await widget.editing.readFacts(saved.id);
      if (!mounted) return;
      if (facts is Failure<ItemEditFacts>) {
        setState(() {
          _busy = false;
          _receipt = 'Item saved. The goal effective date could not be read. Retry the date lookup; the item will not be saved again.';
          _error = facts.error;
        });
        return;
      }
      final goal = (facts as Success<ItemEditFacts>).value.latestGoal;
      receipt += '\nCountdown and earning rates apply to the next session.';
      if (goal != null) {
        receipt +=
            '\nDaily goal ${goal.goal == null ? 'disabled' : 'effective'} from ${goalDate(goal)}.';
      }
    } else {
      receipt += '\nPack prices and grants apply to future purchases. Owned allowances are unchanged.';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _error = null;
        _receipt = receipt;
      });
    }
  }

  Future<void> _archive() async {
    final confirmed = await showTroveDialog<bool>(
      context: context,
      title: 'Archive item?',
      builder: (context) => const Text(
        'Hide future starts or purchases. History and any usable Trove allowance remain available.',
      ),
      actions: [
        Builder(
          builder: (context) => TroveButton(
            label: 'Archive item',
            onPressed: () => Navigator.pop(context, true),
          ),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final item = _draft.original!;
    final result = await widget.editing.repository.archiveItem(
      operationId: widget.editing.operationId(),
      itemId: item.id,
      expectedRevision: item.revision,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result is Failure<Item>) {
        _error = result.error;
      } else {
        _saved = (result as Success<Item>).value;
        _receipt =
            'Archived. History and usable Trove allowances are retained.';
      }
    });
  }

  Future<void> _reload() async {
    setState(() => _busy = true);
    final result = await widget.editing.repository.getItem(_draft.id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result is Success<Item?> && result.value != null) {
        _initialize(result.value);
      } else {
        _error = result is Failure<Item?> ? result.error : const NotFound();
      }
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AbsorbPointer(
      absorbing: _busy,
      child: TroveDialog(
        title: _saved == null
            ? (_draft.original == null ? 'Create item' : 'Configure item')
            : 'Item saved',
        child: _saved != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_receipt != null)
                    Semantics(liveRegion: true, child: Text(_receipt!)),
                  if (_error != null)
                    TroveButton(
                      label: 'Retry effective date',
                      onPressed: _readReceipt,
                    ),
                  const SizedBox(height: 16),
                  TroveButton(
                    label: 'Done',
                    onPressed: () => Navigator.pop(context, _saved),
                  ),
                  if (_busy) const LinearProgressIndicator(),
                ],
              )
            : FutureBuilder<Result<ItemEditFacts>>(
                future: _facts,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final result = snapshot.data!;
                  if (result is Failure<ItemEditFacts>) {
                    return Column(
                      children: [
                        const Text(
                          'Could not load editing details. Your draft is retained.',
                        ),
                        TroveButton(
                          label: 'Retry loading',
                          onPressed: () => setState(
                            () => _facts = widget.editing.readFacts(_draft.id),
                          ),
                        ),
                      ],
                    );
                  }
                  final facts = (result as Success<ItemEditFacts>).value;
                  return StreamBuilder<List<Group>>(
                    stream: _groups,
                    builder: (context, groups) {
                      if (groups.hasError) {
                        return const Text(
                          'Could not load groups. Close and reopen to retry.',
                        );
                      }
                      if (!groups.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      return _buildForm(facts, groups.data!);
                    },
                  );
                },
              ),
      ),
    ),
  );

  Widget _buildForm(ItemEditFacts facts, List<Group> groups) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _choice(
          'Type',
          _draft.type,
          {ItemType.quest: 'Quest', ItemType.award: 'Award'},
          (v) => _draft.type = v,
          enabled: !facts.hasHistory,
        ),
        const SizedBox(height: 16),
        _field(
          'Item name',
          _draft.name,
          (v) => _draft.name = v,
          validator: _required,
        ),
        const SizedBox(height: 16),
        Center(
          child: ItemIcon(
            iconKey: _draft.iconKey,
            palette: ItemPalette.custom(Color(_draft.colorArgb)),
          ),
        ),
        TroveFormRow(
          children: [
            TroveButton(
              label: 'Choose icon',
              secondary: true,
              onPressed: () async {
                final icon = await showIconPicker(
                  context: context,
                  selectedKey: _draft.iconKey,
                  palette: ItemPalette.custom(Color(_draft.colorArgb)),
                );
                if (icon != null && mounted) {
                  _changed(() => _draft.iconKey = icon);
                }
              },
            ),
            TroveButton(
              label: 'Choose color',
              secondary: true,
              onPressed: () async {
                final color = await showItemColorPicker(
                  context: context,
                  color: Color(_draft.colorArgb),
                  iconKey: _draft.iconKey,
                );
                if (color != null && mounted) {
                  _changed(() => _draft.colorArgb = color.toARGB32());
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Use string values because PopupMenuButton treats null as cancellation.
        _choice('Group', _draft.groupId?.value ?? '', {
          '': 'Ungrouped',
          for (final g in groups) g.id.value: g.name,
        }, (v) => _draft.groupId = v.isEmpty ? null : GroupId(v)),
        const SizedBox(height: 16),
        if (facts.hasHistory) ...[
          const Text(
            'History protects type, allowance dimensions and budget currency. Create another item to change them.',
          ),
          TroveButton(
            label: 'Create another item',
            secondary: true,
            onPressed: () => _changed(() => _initialize(null)),
          ),
        ],
        if (_draft.type == ItemType.quest)
          ..._questFields()
        else
          ..._awardFields(facts),
        const SizedBox(height: 16),
        if (_draft.type == ItemType.quest)
          const Text(
            'Countdown and rates apply to the next session. Goal and bonus edits after today’s activity apply the next reporting day; the saved result shows the exact date.',
          ),
        if (_draft.type == ItemType.award)
          const Text(
            'Prices and grants apply to future purchases. Owned allowances and history are unchanged.',
          ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(
              editingError(_error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          if (_error is StaleRevision || _error is NotFound)
            TroveButton(
              label: 'Discard draft and reload',
              secondary: true,
              onPressed: _reload,
            ),
          if (_error is UnsupportedDimensionalEdit && !facts.hasHistory)
            TroveButton(
              label: 'Create another item',
              secondary: true,
              onPressed: () => _changed(() => _initialize(null)),
            ),
        ],
        const SizedBox(height: 20),
        TroveButton(
          label: _busy ? 'Saving…' : 'Save item',
          onPressed: () => _save(),
        ),
        const SizedBox(height: 8),
        if (_draft.original?.archived == true)
          TroveButton(
            label: 'Save and unarchive',
            secondary: true,
            onPressed: () => _save(restore: true),
          ),
        if (_draft.original != null && !_draft.original!.archived) ...[
          TroveButton(
            label: 'Archive item',
            secondary: true,
            onPressed: facts.active ? null : _archive,
          ),
          if (facts.active)
            const Text('End this item’s active session before archiving.'),
          const SizedBox(height: 8),
        ],
        TroveButton(
          label: 'Cancel',
          secondary: true,
          onPressed: () => Navigator.pop(context),
        ),
        if (_busy) const LinearProgressIndicator(),
      ],
    ),
  );

  List<Widget> _questFields() => [
    _duration(
      'Session countdown',
      _draft.duration,
      _draft.durationUnit,
      (v) => _draft.duration = v,
      (v) => _draft.durationUnit = v,
    ),
    const SizedBox(height: 16),
    _choice('Earning rate unit', _draft.rateUnit, {
      for (final unit in TimeUnit.values) unit: 'Per ${unit.name}',
    }, (v) => _draft.rateUnit = v),
    const SizedBox(height: 16),
    TroveFormRow(
      children: [
        _money('Coins earned', _draft.coins, (v) => _draft.coins = v),
        _money('Gems earned', _draft.gems, (v) => _draft.gems = v),
      ],
    ),
    _toggle(
      'Daily time goal',
      _draft.goalEnabled,
      (v) => _draft.goalEnabled = v,
    ),
    if (_draft.goalEnabled) ...[
      _duration(
        'Daily goal',
        _draft.goalDuration,
        _draft.goalUnit,
        (v) => _draft.goalDuration = v,
        (v) => _draft.goalUnit = v,
      ),
      const SizedBox(height: 16),
      TroveFormRow(
        children: [
          _money(
            'Bonus Coins',
            _draft.bonusCoins,
            (v) => _draft.bonusCoins = v,
          ),
          _money('Bonus Gems', _draft.bonusGems, (v) => _draft.bonusGems = v),
        ],
      ),
    ],
  ];

  List<Widget> _awardFields(ItemEditFacts facts) => [
    _field(
      'Purchase pack name',
      _draft.packName,
      (v) => _draft.packName = v,
      validator: _required,
    ),
    const Text('Purchases use whole packs (quantity step: 1).'),
    _toggle(
      'Grant time',
      _draft.timeEnabled,
      (v) => _draft.timeEnabled = v,
      enabled: !facts.hasHistory,
    ),
    if (_draft.timeEnabled)
      _duration(
        'Time per pack',
        _draft.timeGrant,
        _draft.timeUnit,
        (v) => _draft.timeGrant = v,
        (v) => _draft.timeUnit = v,
      ),
    _toggle(
      'Grant spending budget',
      _draft.budgetEnabled,
      (v) => _draft.budgetEnabled = v,
      enabled: !facts.hasHistory,
    ),
    if (_draft.budgetEnabled) ...[
      _field(
        'Budget currency',
        _draft.currencyCode,
        (v) => _draft.currencyCode = v,
        enabled: !facts.hasHistory,
        validator: (value) {
          try {
            BudgetCurrency.fromMetadata(
              (value ?? '').trim().toUpperCase(),
              widget.editing.currencies,
            );
            return null;
          } on DomainError {
            return 'Enter a supported three-letter ISO currency code.';
          }
        },
      ),
      const SizedBox(height: 16),
      _field(
        'Budget per pack',
        _draft.budgetGrant,
        (v) => _draft.budgetGrant = v,
        numeric: true,
        validator: (value) {
          try {
            final currency = BudgetCurrency.fromMetadata(
              _draft.currencyCode.trim().toUpperCase(),
              widget.editing.currencies,
            );
            final amount = BudgetAmount.parse(currency, (value ?? '').trim());
            return amount.minorUnits > 0 ? null : 'Enter a positive budget.';
          } on DomainError {
            return 'Use a positive amount with this currency’s supported precision.';
          }
        },
      ),
    ],
    const SizedBox(height: 16),
    TroveFormRow(
      children: [
        _money(
          'Pack price · Coins',
          _draft.priceCoins,
          (v) => _draft.priceCoins = v,
        ),
        _money(
          'Pack price · Gems',
          _draft.priceGems,
          (v) => _draft.priceGems = v,
        ),
      ],
    ),
    const Text(
      'At least one price must be positive. If both are set, both are required.',
    ),
  ];
}
