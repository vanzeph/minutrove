import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/domain/domain.dart';

import 'items_test.dart' show item, quest, award;

final class FakeClock implements Clock {
  @override
  ClockReading now() => ClockReading(
    utc: DateTime.utc(2026, 1, 1),
    bootId: 'test-boot',
    monotonic: Milliseconds(1000),
  );
}

final class FakeItems implements ItemRepository {
  Item? saved;
  final Map<OperationId, Result<Item>> outcomes = {};
  @override
  Future<Result<Item?>> getItem(ItemId id) async =>
      Success(saved?.id == id ? saved : null);
  @override
  Stream<List<Item>> watchItems() => Stream.value([?saved]);
  @override
  Stream<List<Group>> watchGroups() => Stream.value([]);
  @override
  Future<Result<Item>> saveItem({
    required OperationId operationId,
    required Item item,
    required Revision? expectedRevision,
  }) async {
    if (outcomes.containsKey(operationId)) return outcomes[operationId]!;
    if (saved != null && saved!.revision != expectedRevision) {
      return const Failure(StaleRevision());
    }
    saved = item;
    return outcomes[operationId] = Success(item);
  }

  @override
  Future<Result<Item>> archiveItem({
    required OperationId operationId,
    required ItemId itemId,
    required Revision expectedRevision,
  }) async => const Failure(ActiveSessionConflict());
  @override
  Future<Result<Group>> saveGroup({
    required OperationId operationId,
    required Group group,
    required Revision? expectedRevision,
  }) async => Success(group);
  @override
  Future<Result<List<Item>>> removeGroup({
    required OperationId operationId,
    required GroupId groupId,
    required Revision expectedRevision,
  }) async => const Success([]);
}

final class FakeNotifications implements NotificationScheduler {
  final Map<String, NotificationIntent> pending = {};
  @override
  Future<NotificationPermission> permission() async =>
      NotificationPermission.denied;
  @override
  Future<NotificationPermission> requestPermission({
    required OperationId operationId,
  }) => permission();
  @override
  Future<Result<NotificationPermission>> reconcile({
    required OperationId operationId,
    required List<NotificationIntent> intents,
  }) async {
    pending.clear();
    for (final intent in intents) {
      if (intent.deadlineUtc != null) pending[intent.stableIdentifier] = intent;
    }
    return Success(await permission());
  }

  @override
  Future<Result<bool>> openSystemSettings({
    required OperationId operationId,
  }) async => const Success(true);
}

void main() {
  final operation = OperationId('00000000-0000-0000-0000-000000000099');
  test(
    'downstream code can consume item repository using a typed fake',
    () async {
      final ItemRepository repository = FakeItems();
      final proposed = item(quest());
      final result = await repository.saveItem(
        operationId: operation,
        item: proposed,
        expectedRevision: null,
      );
      final committed = switch (result) {
        Success<Item>(:final value) => value,
        Failure<Item>(:final error) => throw error,
      };
      expect(
        (await repository.getItem(committed.id) as Success<Item?>).value,
        committed,
      );
      expect(await repository.watchItems().first, [committed]);
      expect(
        await repository.saveItem(
          operationId: operation,
          item: proposed,
          expectedRevision: null,
        ),
        same(result),
      );
    },
  );

  test(
    'clock and notification contracts work without platform types',
    () async {
      final Clock clock = FakeClock();
      final scheduler = FakeNotifications();
      final time = clock.now();
      final intent = NotificationIntent(
        sessionId: SessionId(operation.value),
        sessionRevision: Revision(1),
        completionId: CompletionId(operation.value),
        deadlineUtc: time.utc.add(const Duration(minutes: 1)),
        completionChimeHandled: false,
      );
      final result = await scheduler.reconcile(
        operationId: operation,
        intents: [intent, intent],
      );
      expect(
        (result as Success<NotificationPermission>).value,
        NotificationPermission.denied,
      );
      expect(scheduler.pending.length, 1);
      await scheduler.reconcile(operationId: operation, intents: []);
      expect(scheduler.pending, isEmpty);
    },
  );

  test(
    'session snapshot collections are immutable and invalid states reject',
    () {
      final clock = FakeClock().now();
      final intervals = <ActiveInterval>[];
      Session make(
        SessionStatus status, {
        int settled = 0,
        DateTime? deadline,
      }) => Session(
        id: SessionId(operation.value),
        revision: Revision(1),
        itemSnapshot: item(award()),
        status: status,
        zone: ReportingZone('Etc/UTC'),
        startedAt: clock,
        checkpoint: clock,
        duration: Milliseconds(1000),
        settled: Milliseconds(settled),
        deadlineUtc: deadline,
        completionId: CompletionId(operation.value),
        intervals: intervals,
      );
      final paused = make(SessionStatus.paused);
      expect(paused.occupiesSlot, isTrue);
      expect(() => paused.intervals.clear(), throwsUnsupportedError);
      expect(() => make(SessionStatus.running), throwsA(isA<InvalidInput>()));
      expect(() => make(SessionStatus.completed), throwsA(isA<InvalidInput>()));
      expect(
        () => make(SessionStatus.ended, settled: 1001),
        throwsA(isA<InvalidInput>()),
      );
      expect(
        make(SessionStatus.completed, settled: 1000).occupiesSlot,
        isFalse,
      );
    },
  );

  test('backup data and metadata cannot change after validation', () {
    final source = [1, 2, 3];
    final file = BackupFile(source);
    source[0] = 0;
    expect(file.bytes[0], 1);
    expect(() => file.bytes[0] = 4, throwsUnsupportedError);
    final counts = {'items': 2};
    final preview = BackupPreview(
      version: BackupVersion(1),
      createdUtc: DateTime.utc(2026),
      sha256: 'a' * 64,
      recordCounts: counts,
    );
    counts['items'] = 7;
    expect(preview.recordCounts['items'], 2);
    expect(() => preview.recordCounts.clear(), throwsUnsupportedError);
    expect(() => BackupFile([256]), throwsA(isA<InvalidInput>()));
  });

  test('stats rejects mixed dimensions and inconsistent item filters', () {
    expect(
      () => StatsQuery(
        period: StatsPeriod.daily,
        anchor: DayKey(2026, 1, 1),
        category: StatsCategory.all,
        metric: StatsMetric.budgetSpent,
      ),
      throwsA(isA<InvalidInput>()),
    );
    expect(
      () => StatsQuery(
        period: StatsPeriod.weekly,
        anchor: DayKey(2026, 1, 1),
        category: StatsCategory.quests,
        metric: StatsMetric.awardTime,
      ),
      throwsA(isA<InvalidInput>()),
    );
    expect(
      () => StatsQuery(
        period: StatsPeriod.yearly,
        anchor: DayKey(2026, 1, 1),
        category: StatsCategory.item,
        metric: StatsMetric.questTime,
      ),
      throwsA(isA<InvalidInput>()),
    );
  });

  test('all domain imports stay inside domain or Dart core libraries', () {
    final files = Directory('lib/domain')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    final imports = RegExp("(?:import|export) ['\"]([^'\"]+)['\"]");
    for (final file in files) {
      for (final match in imports.allMatches(file.readAsStringSync())) {
        final uri = match.group(1)!;
        expect(
          uri.startsWith('dart:') ||
              (!uri.contains('/') && uri.endsWith('.dart')),
          isTrue,
          reason: '${file.path}: $uri',
        );
        expect(uri, isNot('dart:ui'));
        expect(uri, isNot('dart:io'));
      }
    }
  });
}
