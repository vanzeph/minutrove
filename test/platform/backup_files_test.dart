import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/domain/domain.dart';
import 'package:minutrove/platform/files/backup_files.dart';

typedef NativeHandler = Future<Object?> Function(MethodCall call);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannelBackupFiles adapter;
  late List<MethodCall> calls;

  Future<T> withHandler<T>(NativeHandler handler, Future<T> Function() action) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(adapter.channel, (call) async {
          calls.add(call);
          return handler(call);
        });
    return action();
  }

  setUp(() {
    adapter = const MethodChannelBackupFiles();
    calls = [];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(adapter.channel, null);
  });

  test('pickBackup returns the selected bytes', () async {
    final response = Uint8List.fromList([1, 2, 254, 255]);
    final bytes = await withHandler(
      (call) async => response,
      () => adapter.pickBackup(),
    );
    expect(bytes, response);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'pickBackup');
    expect(calls.single.arguments, isNull);
  });

  test('pickBackup maps native cancellation to null', () async {
    final bytes = await withHandler(
      (call) async => null,
      () => adapter.pickBackup(),
    );
    expect(bytes, isNull);
    expect(calls, hasLength(1));
  });

  test('pickBackup maps the cancelled error code to null', () async {
    final bytes = await withHandler(
      (call) async => throw PlatformException(code: 'pick_cancelled'),
      () => adapter.pickBackup(),
    );
    expect(bytes, isNull);
  });

  test('pickBackup maps platform failure to StorageUnavailable', () async {
    await expectLater(
      withHandler(
        (call) async => throw PlatformException(code: 'pick_read_failed'),
        () => adapter.pickBackup(),
      ),
      throwsA(isA<StorageUnavailable>()),
    );
  });

  test('shareBackup forwards the file name and bytes', () async {
    final bytes = Uint8List.fromList([9, 9, 9]);
    final result = await withHandler(
      (call) async => true,
      () => adapter.shareBackup(
        fileName: 'minutrove-2026-09-14.minutrove',
        bytes: bytes,
      ),
    );
    expect(calls.single.method, 'shareBackup');
    final arguments = calls.single.arguments as Map<Object?, Object?>;
    expect(arguments['fileName'], 'minutrove-2026-09-14.minutrove');
    expect(arguments['bytes'], bytes);
    expect(result, isA<Success<bool>>());
    expect((result as Success<bool>).value, isTrue);
  });

  test('shareBackup answers false when the platform declines', () async {
    final result = await withHandler(
      (call) async => false,
      () => adapter.shareBackup(
        fileName: 'minutrove-2026-09-14.minutrove',
        bytes: Uint8List.fromList([9]),
      ),
    );
    expect((result as Success<bool>).value, isFalse);
  });

  test('shareBackup maps platform failure to typed storage failure', () async {
    final result = await withHandler(
      (call) async => throw PlatformException(code: 'share_failed'),
      () => adapter.shareBackup(
        fileName: 'minutrove-2026-09-14.minutrove',
        bytes: Uint8List.fromList([9]),
      ),
    );
    expect(result, isA<Failure<bool>>());
    expect((result as Failure<bool>).error, isA<StorageUnavailable>());
  });
}
