import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minutrove/platform/audio/completion_chime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(CompletionChime.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'concurrent/repeated callbacks submit one native request per completion',
    () async {
      final gate = Completer<String>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        return gate.future;
      });
      final chime = CompletionChime();
      final first = chime.playOnce('session-a');
      expect(await chime.playOnce('session-a'), ChimeResult.duplicate);
      gate.complete('submitted');
      expect(await first, ChimeResult.submitted);
      expect(await chime.playOnce('session-a'), ChimeResult.duplicate);
      expect(calls.single.method, 'playOnce');
      expect(calls.single.arguments, {'completionId': 'session-a'});
      expect(await chime.playOnce('session-b'), ChimeResult.submitted);
      expect(calls.length, 2);
    },
  );

  test(
    'permission suppression is terminal and does not retry or prompt',
    () async {
      var count = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        count++;
        return 'suppressed';
      });
      final chime = CompletionChime();
      expect(await chime.playOnce('denied'), ChimeResult.suppressed);
      expect(await chime.playOnce('denied'), ChimeResult.duplicate);
      expect(count, 1);
    },
  );

  test('ambiguous native failure never causes automatic repeat', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'submission_failed');
    });
    final chime = CompletionChime();
    await expectLater(
      chime.playOnce('failed'),
      throwsA(isA<PlatformException>()),
    );
    expect(await chime.playOnce('failed'), ChimeResult.duplicate);
  });

  test('invalid identifiers do not reach native code', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => fail('Native call'),
    );
    final chime = CompletionChime();
    await expectLater(chime.playOnce(''), throwsArgumentError);
    await expectLater(chime.playOnce('x' * 129), throwsArgumentError);
  });
}
