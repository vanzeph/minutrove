#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Render Minutrove's original, sample-free 'Pocket Victory' cue."""
import argparse
import hashlib
import io
import math
from pathlib import Path
import struct
import wave

ROOT = Path(__file__).resolve().parents[1]
OUTPUTS = [ROOT / 'assets/audio/completion_chime.wav',
           ROOT / 'android/app/src/main/res/raw/completion_chime.wav',
           ROOT / 'ios/Runner/completion_chime.wav']
RATE = 44100
DURATION = 1.08
# Original rising pentatonic motif: E5, G5, A5, E6 with a soft A6 sparkle.
NOTES = [(0.02, 0.16, 659.255, 0.20), (0.18, 0.16, 783.991, 0.20),
         (0.34, 0.19, 880.0, 0.21), (0.53, 0.45, 1318.510, 0.20),
         (0.65, 0.30, 1760.0, 0.065)]


def render():
    frames = bytearray()
    for index in range(round(RATE * DURATION)):
        t = index / RATE
        sample = 0.0
        for start, length, frequency, gain in NOTES:
            elapsed = t - start
            if not 0 <= elapsed < length:
                continue
            # Band-limited odd harmonics retain a pixel timbre without a harsh
            # discontinuous square wave. Fade every note to avoid clicks.
            envelope = min(1.0, elapsed / 0.008, (length - elapsed) / 0.055)
            envelope *= math.exp(-2.5 * elapsed / length)
            tone = sum(math.sin(2 * math.pi * frequency * h * elapsed) / h
                       for h in (1, 3, 5, 7) if frequency * h < RATE / 2)
            sample += gain * envelope * tone
        assert abs(sample) < 0.8, 'Clipping/headroom regression'
        frames.extend(struct.pack('<h', round(sample * 32767)))
    buffer = io.BytesIO()
    with wave.open(buffer, 'wb') as output:
        output.setparams((1, 2, RATE, 0, 'NONE', 'not compressed'))
        output.writeframes(frames)
    return buffer.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    data = render()
    for path in OUTPUTS:
        if args.check:
            assert path.read_bytes() == data, f'Regenerate {path.relative_to(ROOT)}'
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    print(f'PCM WAV mono 16-bit {RATE} Hz; {DURATION}s; {len(data)} bytes')
    print('sha256:', hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    main()
