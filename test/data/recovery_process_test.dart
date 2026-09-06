import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  final epoch = DateTime.utc(2026, 1, 15, 12).millisecondsSinceEpoch;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('minutrove-process-'),
  );
  tearDown(() => directory.delete(recursive: true));

  Future<Map<String, dynamic>> run(
    String mode,
    int operation, {
    int elapsed = 0,
    int? wall,
    String boot = 'boot-a',
  }) async {
    final process = await Process.start('dart', [
      '--packages=.dart_tool/package_config.json',
      'test/support/recovery_process.dart',
      '${directory.path}/durable.db',
      mode,
      '${epoch + (wall ?? elapsed)}',
      '${1000 + elapsed}',
      boot,
      '$operation',
    ]);
    final errors = process.stderr.transform(utf8.decoder).join();
    try {
      final line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 30));
      return jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
      throw StateError('Recovery subprocess failed: ${await errors}');
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }

  test('SIGKILL and relaunch retain same-boot accounting despite wall rollback/forward', () async {
    final started = await run('start', 101);
    final backward = await run('recover', 102, elapsed: 10000, wall: -3600000);
    expect(backward['settled'], 10000);
    expect(backward['coins'], 2777);
    final forward = await run('recover', 103, elapsed: 20000, wall: 3600000);
    expect(forward['settled'], 20000);
    expect(forward['status'], 'running');
    final completed = await run('recover', 104, elapsed: 90000, wall: 7200000);
    expect(completed['settled'], 60000);
    expect(
      completed['coins'],
      16676,
    ); // Ordinary earnings plus one daily bonus.
    expect(completed['achievements'], 1);
    expect(completed['completionId'], started['completionId']);
    expect(completed['active'], isFalse);
    final duplicate = await run('replay', 104, elapsed: 9999999);
    expect(duplicate, completed);
    final another = await run('recover', 105, elapsed: 9999999);
    expect(another['coins'], completed['coins']);
    expect(another['revision'], completed['revision']);
    final log = await File('${directory.path}/durable.db.diagnostics')
        .readAsLines();
    expect(log, ['wallClockBackward', 'wallClockForward', 'wallClockForward']);
  });

  test(
    'paused SIGKILL and reboot retain pause; resume establishes a new deadline',
    () async {
      await run('start', 101);
      final paused = await run('pause', 102, elapsed: 10000);
      final recovered = await run(
        'recover',
        103,
        elapsed: 0,
        wall: 86400000,
        boot: 'boot-b',
      );
      expect(recovered['status'], 'paused');
      expect(recovered['settled'], 10000);
      expect(recovered['deadline'], isNull);
      expect(recovered['coins'], paused['coins']);
      final resumed = await run('resume', 104, wall: 86400000, boot: 'boot-b');
      expect(resumed['deadline'], epoch + 86450000);
      final completed = await run(
        'recover',
        105,
        elapsed: 50000,
        wall: 86450000,
        boot: 'boot-b',
      );
      expect(completed['settled'], 60000);
      expect(completed['coins'], 16666); // Neither local date reached the goal.
      expect(completed['achievements'], 0);
    },
  );

  test('reboot rollback reanchors at zero; forward recovery is capped at the persisted deadline', () async {
    await run('start', 101);
    await run('recover', 102, elapsed: 10000);
    final reversed = await run(
      'recover',
      103,
      elapsed: 0,
      wall: -3600000,
      boot: 'boot-b',
    );
    expect(reversed['settled'], 10000);
    expect(reversed['deadline'], epoch - 3550000);
    final resumed = await run(
      'recover',
      104,
      elapsed: 10000,
      wall: -3590000,
      boot: 'boot-b',
    );
    expect(resumed['settled'], 20000);
    final completed = await run(
      'recover',
      105,
      elapsed: 0,
      wall: 86400000,
      boot: 'boot-c',
    );
    expect(completed['settled'], 60000);
    expect(completed['status'], 'completed');
    expect(completed['coins'], 16676);
    expect(completed['achievements'], 1);
    expect(
      await File('${directory.path}/durable.db.diagnostics').readAsLines(),
      ['bootChanged', 'bootChanged'],
    );
  });
}
