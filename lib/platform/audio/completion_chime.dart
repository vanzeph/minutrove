import 'package:flutter/services.dart';

/// Submission is not a promise of audibility: the OS owns sound policy.
enum ChimeResult { submitted, suppressed, duplicate }

/// One-shot completion cue delivered through the system notification sound path.
///
/// The session coordinator must durably consume its completion sound intent
/// before calling this adapter, and must not call it for an already scheduled
/// OS notification or replay it on restore/relaunch. This adapter only coalesces
/// duplicate calls for the lifetime of this instance; it is not a session ledger.
/// Keep one instance for the app lifetime. No permission prompt is issued here.
class CompletionChime {
  CompletionChime({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'io.github.vanzeph.minutrove/completion_chime';
  static const iosSoundName = 'completion_chime.wav';
  static const androidSoundResource = 'completion_chime';
  static const androidChannelId = 'minutrove_completion_v1';

  final MethodChannel _channel;
  final Set<String> _requested = {};

  Future<ChimeResult> playOnce(String completionId) async {
    if (completionId.isEmpty || completionId.length > 128) {
      throw ArgumentError.value(completionId, 'completionId');
    }
    if (!_requested.add(completionId)) return ChimeResult.duplicate;
    // Retain the marker even on failure: the OS may have accepted the request
    // before the channel failed. Automatically retrying could repeat the sound.
    final result = await _channel.invokeMethod<String>('playOnce', {
      'completionId': completionId,
    });
    return switch (result) {
      'submitted' => ChimeResult.submitted,
      'suppressed' => ChimeResult.suppressed,
      _ => throw PlatformException(code: 'invalid_chime_result'),
    };
  }
}
