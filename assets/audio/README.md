# Pocket Victory

An original 1.08-second pixel-game completion cue made for Minutrove by Codex
(OpenAI), 6 September 2026. The score, additive synthesis code, and recording were
created for this contribution. No sampled recording, sound library, third-party
melody, model-generated audio, or external audio service was used.

License: **AGPL-3.0-only**, the same as the original repository contributions.
See [LICENSE](../../LICENSE). This notice identifies creation provenance; it does
not assert exclusive rights over the individual musical notes.

The motif rises through E5–G5–A5–E6 with a quiet A6 sparkle. Odd harmonics provide
the pixel timbre, with an 8 ms attack and a soft release on each note. The final
100 ms is silent. The cue contains no loop metadata or repeating alarm.

- Format: RIFF/WAVE, linear PCM, signed 16-bit little endian, mono, 44,100 Hz.
- Duration: 47,628 frames / 1.08 seconds; 95,300 bytes.
- SHA-256: `3e56356389230bae9e6aa0d51fb071db09d82d284d0dcfc6f322ef5286da3e18`.
- Source: [generate_chime.py](../../tool/generate_chime.py).

Run `python3 tool/generate_chime.py` to regenerate all three identical files;
`python3 tool/generate_chime.py --check` checks them against the score. The copy
here is for preview/provenance, not a Flutter asset. Android bundles only its
`res/raw/completion_chime.wav`; iOS bundles only `Runner/completion_chime.wav`.
One PCM format works on both platforms, so no redundant encoded format is shipped.
On macOS, preview the exact asset with `afplay assets/audio/completion_chime.wav`.

## Sound adapter contract

`lib/platform/audio/completion_chime.dart` exposes `CompletionChime.playOnce(id)`.
Keep one adapter for the application lifetime. It coalesces concurrent/repeated
IDs, submits once, and returns `submitted`, `suppressed`, or `duplicate`. Native
submission errors propagate as `PlatformException` and are not automatically
retried, because the OS may already have accepted the sound. A submitted request
is **not** proof of audible delivery.

The implementation uses a normal, immediate OS notification, with generic
session-completion text when backgrounded. iOS presents sound only in foreground.
It does not prompt for permissions, change volume, play background media, vibrate,
loop, use critical/time-sensitive alerts, request DND bypass, or start a session.
Android API 24–25 uses notification audio attributes; API 26+ uses the normal
`minutrove_completion_v1` channel and preserves the user's existing channel
settings. The URI uses the resource name, so numeric resource ID changes do not
invalidate the channel. iOS uses `UNNotificationSound` with the bundled WAV.
Silent, Focus, channel choices, permission denial, and OS policy can suppress
sound. Notification permission onboarding belongs to the notification feature.

The session/notification coordinator owns **durable** completion identity and
sound intent. It must consume that intent before calling this adapter, must not
replay it on restart/restore, and must not call the immediate adapter if a deadline
notification already owns this completion. In-memory coalescing does not replace
that ledger. For scheduled notifications, reuse `completion_chime.wav` on iOS and
`completion_chime` / `minutrove_completion_v1` on Android; use the same
`minutrove.completion.<completionId>` notification identifier/tag. The downstream
scheduler owns cancellation, deadline reconciliation, and tap-to-settlement.
This contribution does not yet connect the synthetic shell to a real session.

## Verification

`flutter test` checks duplicate/concurrent calls, separate completions, suppression,
invalid IDs, and ambiguous native errors. Native CI plays the actual bundled
asset with Android MediaPlayer and iOS AVAudioPlayer, checks one completion and
no restart, and verifies the one-shot notification configuration. Android tests
also open the sound URI used by the actual notification channel. These synthetic
native-player checks verify decoding and playback duration; they do not claim a
human heard emulator audio or certify physical-device Focus/volume behavior.
Physical-device notification policy checks belong to native acceptance and remain
necessary for end-to-end delivery.

Platform references: [Apple notification sounds](https://developer.apple.com/documentation/usernotifications/unnotificationsound),
[Android notification channels](https://developer.android.com/reference/android/app/NotificationChannel),
[Android notification builder](https://developer.android.com/reference/android/app/Notification.Builder).
