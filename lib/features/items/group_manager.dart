import 'package:flutter/material.dart';

import '../../domain/domain.dart';
import '../../ui/core/core.dart';
import 'item_editing.dart';
import 'item_editor.dart';

Future<void> showGroupManager({
  required BuildContext context,
  required ItemEditing editing,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => GroupManager(editing: editing),
);

/// Explicit layout mode. Reordering changes only order; Configure also moves an
/// item between groups. Every command uses the displayed revision, and a failed
/// sequence stops with an honest partial-order notice and the live saved state.
class GroupManager extends StatefulWidget {
  const GroupManager({super.key, required this.editing});
  final ItemEditing editing;
  @override
  State<GroupManager> createState() => _GroupManagerState();
}

class _GroupManagerState extends State<GroupManager> {
  late Stream<List<Group>> _groups = widget.editing.repository.watchGroups();
  late Stream<List<Item>> _items = widget.editing.repository.watchItems();
  bool _busy = false;
  String? _error;
  bool _archived = false;

  Future<void> _group(Group? group, int nextOrder) async {
    await showDialog<Group>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _GroupEditor(editing: widget.editing, group: group, order: nextOrder),
    );
  }

  Future<void> _remove(Group group) async {
    final confirm = await showTroveDialog<bool>(
      context: context,
      title: 'Remove ${group.name}?',
      builder: (_) => const Text(
        'All items in this group, including archived items, move to Ungrouped. Their history and allowances stay intact.',
      ),
      actions: [
        Builder(
          builder: (context) => TroveButton(
            label: 'Remove group',
            onPressed: () => Navigator.pop(context, true),
          ),
        ),
      ],
    );
    if (confirm != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.editing.repository.removeGroup(
      operationId: widget.editing.operationId(),
      groupId: group.id,
      expectedRevision: group.revision,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result is Failure<List<Item>>) _error = editingError(result.error);
    });
  }

  Future<void> _reorder<T>(
    List<T> current,
    int from,
    int to,
    Future<DomainError?> Function(T, int) save,
  ) async {
    final ordered = List<T>.of(current);
    ordered.insert(to, ordered.removeAt(from));
    setState(() {
      _busy = true;
      _error = null;
    });
    var completed = 0;
    for (var i = 0; i < ordered.length; i++) {
      final failure = await save(ordered[i], i);
      if (failure != null) {
        if (mounted) {
          setState(
            () => _error =
                '${editingError(failure)}${completed > 0 ? ' Some order changes were saved; the list shows the current saved order. Retry from this order.' : ''}',
          );
        }
        break;
      }
      completed++;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<DomainError?> _saveGroupOrder(Group group, int order) async {
    if (group.order == order) return null;
    final result = await widget.editing.repository.saveGroup(
      operationId: widget.editing.operationId(),
      expectedRevision: group.revision,
      group: Group(
        id: group.id,
        revision: group.revision,
        name: group.name,
        order: order,
      ),
    );
    return result is Failure<Group> ? result.error : null;
  }

  Future<DomainError?> _saveItemOrder(Item item, int order) async {
    if (item.order == order) return null;
    final result = await widget.editing.repository.saveItem(
      operationId: widget.editing.operationId(),
      expectedRevision: item.revision,
      item: Item(
        id: item.id,
        revision: item.revision,
        name: item.name,
        iconKey: item.iconKey,
        colorArgb: item.colorArgb,
        groupId: item.groupId,
        order: order,
        archived: item.archived,
        configuration: item.configuration,
      ),
    );
    return result is Failure<Item> ? result.error : null;
  }

  Widget _moves(String name, int index, int length, void Function(int) move) =>
      Wrap(
        spacing: 8,
        children: [
          IconButton(
            tooltip: 'Move $name earlier',
            onPressed: index == 0 ? null : () => move(index - 1),
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton(
            tooltip: 'Move $name later',
            onPressed: index + 1 == length ? null : () => move(index + 1),
            icon: const Icon(Icons.arrow_downward),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AbsorbPointer(
      absorbing: _busy,
      child: TroveDialog(
        title: 'Manage layout',
        child: StreamBuilder<List<Group>>(
          stream: _groups,
          builder: (context, groupsSnapshot) => StreamBuilder<List<Item>>(
            stream: _items,
            builder: (context, itemsSnapshot) {
              if (groupsSnapshot.hasError || itemsSnapshot.hasError) {
                return Column(
                  children: [
                    const Text('Could not load your layout.'),
                    TroveButton(
                      label: 'Retry loading',
                      onPressed: () => setState(() {
                        _groups = widget.editing.repository.watchGroups();
                        _items = widget.editing.repository.watchItems();
                      }),
                    ),
                  ],
                );
              }
              if (!groupsSnapshot.hasData || !itemsSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final groups = List<Group>.of(groupsSnapshot.data!)
                ..sort((a, b) {
                  final order = a.order.compareTo(b.order);
                  return order == 0 ? a.id.value.compareTo(b.id.value) : order;
                });
              final items = List<Item>.of(itemsSnapshot.data!)
                ..sort((a, b) {
                  final order = a.order.compareTo(b.order);
                  return order == 0 ? a.id.value.compareTo(b.id.value) : order;
                });
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Organize groups and items. Changes save as you go. Configure an item to move it to another group.',
                  ),
                  const SizedBox(height: 16),
                  TroveButton(
                    label: 'Create item',
                    onPressed: () => showItemEditor(
                      context: context,
                      editing: widget.editing,
                    ),
                  ),
                  TroveButton(
                    label: 'New group',
                    secondary: true,
                    onPressed: () => _group(
                      null,
                      groups.isEmpty ? 0 : groups.last.order + 1,
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show archived items'),
                    value: _archived,
                    onChanged: (v) => setState(() => _archived = v!),
                  ),
                  if (_error != null)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_busy) const LinearProgressIndicator(),
                  for (final group in <Group?>[...groups, null]) ...[
                    const SizedBox(height: 20),
                    Semantics(
                      header: true,
                      child: Text(
                        group?.name ?? 'Ungrouped',
                        style: TroveTokens.heading,
                      ),
                    ),
                    if (group != null) ...[
                      TroveFormRow(
                        children: [
                          TroveButton(
                            label: 'Rename ${group.name}',
                            secondary: true,
                            onPressed: () => _group(group, group.order),
                          ),
                          TroveButton(
                            label: 'Remove ${group.name}',
                            secondary: true,
                            onPressed: () => _remove(group),
                          ),
                        ],
                      ),
                      _moves(
                        group.name,
                        groups.indexOf(group),
                        groups.length,
                        (to) => _reorder(
                          groups,
                          groups.indexOf(group),
                          to,
                          _saveGroupOrder,
                        ),
                      ),
                    ],
                    ..._itemRows(
                      items.where((i) => i.groupId == group?.id).toList(),
                    ),
                  ],
                  const SizedBox(height: 20),
                  TroveButton(
                    label: 'Done',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  List<Widget> _itemRows(List<Item> all) {
    final visible = all.where((i) => _archived || !i.archived).toList();
    return [
      if (visible.isEmpty) const Text('No items in this group.'),
      for (final item in visible)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${item.name} · ${item.type == ItemType.quest ? 'Quest' : 'Award'}${item.archived ? ' · Archived' : ''}',
                style: TroveTokens.label,
              ),
              TroveButton(
                label: 'Configure ${item.name}',
                secondary: true,
                onPressed: () => showItemEditor(
                  context: context,
                  editing: widget.editing,
                  item: item,
                ),
              ),
              _moves(
                item.name,
                visible.indexOf(item),
                visible.length,
                (to) => _reorder(
                  visible,
                  visible.indexOf(item),
                  to,
                  _saveItemOrder,
                ),
              ),
            ],
          ),
        ),
    ];
  }
}

class _GroupEditor extends StatefulWidget {
  const _GroupEditor({
    required this.editing,
    required this.group,
    required this.order,
  });
  final ItemEditing editing;
  final Group? group;
  final int order;
  @override
  State<_GroupEditor> createState() => _GroupEditorState();
}

class _GroupEditorState extends State<_GroupEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.group?.name ?? '');
  late final _id = widget.group?.id ?? GroupId(widget.editing.newUuid());
  OperationId? _operation;
  DomainError? _error;
  bool _busy = false;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.editing.repository.saveGroup(
      operationId: _operation ??= widget.editing.operationId(),
      expectedRevision: widget.group?.revision,
      group: Group(
        id: _id,
        revision: widget.group?.revision ?? Revision(1),
        name: _name.text.trim(),
        order: widget.order,
      ),
    );
    if (!mounted) return;
    if (result is Success<Group>) {
      Navigator.pop(context, result.value);
    } else {
      setState(() {
        _busy = false;
        _error = (result as Failure<Group>).error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AbsorbPointer(
      absorbing: _busy,
      child: TroveDialog(
        title: widget.group == null ? 'New group' : 'Rename group',
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TroveTextField(
                label: 'Group name',
                controller: _name,
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Enter a group name.' : null,
                onChanged: (_) {
                  _operation = null;
                },
              ),
              if (_error != null)
                Semantics(liveRegion: true, child: Text(editingError(_error!))),
              const SizedBox(height: 20),
              TroveButton(label: 'Save group', onPressed: _save),
              TroveButton(
                label: 'Cancel',
                secondary: true,
                onPressed: () => Navigator.pop(context),
              ),
              if (_busy) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
    ),
  );
}
