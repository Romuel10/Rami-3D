#!/usr/bin/env python3
"""Re-create the three original Rami Salon instrumental loops.

Requires Python 3, numpy, scipy and ffmpeg. No recordings or downloaded samples
are used. WAV intermediates are written outside the game project by default.
The compositions and their generated audio are dedicated to CC0 1.0.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import subprocess
import tempfile
import wave

import numpy as np
from scipy.signal import butter, sosfilt

RATE = 32000
TAU = math.tau


def frequency(midi: int) -> float:
    return 440.0 * 2.0 ** ((midi - 69) / 12.0)


def envelope(t: np.ndarray, length: float, attack: float = 0.008, release: float = 0.12) -> np.ndarray:
    return np.minimum(1.0, t / attack) * np.minimum(1.0, np.maximum(0.0, (length - t) / release))


def voice(note: int, seconds: float, kind: str, rng: np.random.Generator) -> np.ndarray:
    t = np.arange(int(seconds * RATE), dtype=np.float64) / RATE
    f = frequency(note)
    if kind == 'guitar':
        # An articulated nylon-like pluck: each upper partial fades faster.
        wave_data = sum((0.58 ** (h - 1)) / math.sqrt(h) * np.sin(TAU * f * h * t + 0.09 * h)
                        * np.exp(-t * (1.8 + h * 0.85)) for h in range(1, 9))
        wave_data += 0.008 * rng.standard_normal(t.size) * np.exp(-70 * t)
        wave_data *= envelope(t, seconds, 0.006, 0.09)
    elif kind == 'piano':
        # Slightly inharmonic, two-string partials with a quiet felt hammer.
        wave_data = np.zeros(t.size)
        for h in range(1, 9):
            overtone = f * h * math.sqrt(1 + 0.000085 * h * h)
            partial = (np.sin(TAU * overtone * t) + 0.38 * np.sin(TAU * overtone * 1.0008 * t)) / 1.38
            wave_data += partial * (0.55 ** (h - 1)) * np.exp(-t * (0.72 + h * 0.39))
        hammer = sosfilt(butter(2, 3500, fs=RATE, output='sos'), rng.standard_normal(t.size))
        wave_data += 0.012 * hammer * np.exp(-45 * t)
        wave_data *= envelope(t, seconds, 0.004, 0.22)
    elif kind == 'rhodes':
        wave_data = (np.sin(TAU * f * t + 0.65 * np.sin(TAU * f * 2 * t) * np.exp(-3.0 * t))
                     + 0.16 * np.sin(TAU * f * 3 * t) * np.exp(-5 * t))
        wave_data *= np.exp(-1.15 * t) * envelope(t, seconds, 0.014, 0.21)
    elif kind == 'pad':
        wave_data = (np.sin(TAU * f * t) + 0.32 * np.sin(TAU * f * 2.001 * t)
                     + 0.13 * np.sin(TAU * f * 3.002 * t)) / 1.45
        wave_data *= envelope(t, seconds, 0.48, 0.80) * (0.97 + 0.03 * np.sin(TAU * 0.25 * t))
    elif kind == 'bass':
        wave_data = (np.sin(TAU * f * t) + 0.18 * np.sin(TAU * f * 2 * t))
        wave_data *= np.exp(-1.05 * t) * envelope(t, seconds, 0.024, 0.18)
    else:
        raise ValueError(kind)
    return wave_data


def percussion(kind: str, rng: np.random.Generator) -> np.ndarray:
    seconds = 0.38 if kind == 'kick' else 0.15
    t = np.arange(int(seconds * RATE), dtype=np.float64) / RATE
    if kind == 'kick':
        # Integrated exponential pitch gives a mellow, click-free low pulse.
        phase = TAU * (46 * t + (56 / 35) * (1 - np.exp(-35 * t)))
        data = np.sin(phase) * np.exp(-13 * t) * envelope(t, seconds, 0.004, 0.04)
    else:
        noise = rng.standard_normal(t.size)
        if kind == 'brush':
            noise = sosfilt(butter(2, [650, 5500], btype='bandpass', fs=RATE, output='sos'), noise)
            data = noise * np.exp(-28 * t) * envelope(t, seconds, 0.005, 0.025)
        else:
            noise = sosfilt(butter(2, [4500, 10500], btype='bandpass', fs=RATE, output='sos'), noise)
            data = noise * np.exp(-48 * t) * envelope(t, seconds, 0.003, 0.025)
    return data


def compose(name: str, bpm: float, kind: str, seed: int, wav_dir: Path, output_dir: Path) -> dict:
    beat = 60.0 / bpm
    length = beat * 64   # Sixteen 4/4 bars; every tail wraps into the next repetition.
    count = round(length * RATE)
    mix = np.zeros((count, 2), dtype=np.float64)
    rng = np.random.default_rng(seed)

    def add(data: np.ndarray, start_beat: float, gain: float, pan: float = 0.0) -> None:
        start = round(start_beat * beat * RATE) % count
        # Equal-power stereo pan, with a narrow field for comfortable phone listening.
        angle = (pan + 1.0) * math.pi / 4
        weights = np.array([math.cos(angle), math.sin(angle)]) * gain
        position = 0
        while position < data.size:
            amount = min(count - start, data.size - position)
            mix[start:start + amount] += data[position:position + amount, None] * weights
            position += amount
            start = 0

    progression = [
        [48, 52, 55, 59], [45, 48, 52, 55], [41, 45, 48, 52], [43, 47, 50, 55],
        [48, 52, 55, 59], [40, 47, 50, 55], [38, 45, 48, 53], [43, 48, 50, 55],
        [48, 52, 55, 59], [45, 48, 52, 55], [41, 45, 48, 52], [43, 47, 50, 55],
        [48, 52, 55, 59], [45, 48, 52, 55], [38, 45, 48, 53], [43, 47, 50, 55],
    ]
    # Four small original phrases, answered and varied in the second half.
    melody = [
        [(0.25, 64), (1.0, 67), (2.0, 71), (3.0, 67)],
        [(0.0, 69), (1.5, 67), (2.5, 64)],
        [(0.5, 65), (1.5, 69), (2.5, 72), (3.5, 69)],
        [(0.0, 67), (1.0, 62), (2.5, 64), (3.25, 62)],
        [(0.0, 64), (1.0, 67), (2.25, 71), (3.25, 72)],
        [(0.25, 71), (1.5, 67), (3.0, 64)],
        [(0.0, 65), (1.5, 69), (2.5, 72)],
        [(0.0, 69), (1.25, 67), (2.25, 62), (3.0, 59)],
    ]
    for bar, chord in enumerate(progression):
        base = 4 * bar
        bass_note = chord[0] - (12 if chord[0] >= 45 else 0)
        add(voice(bass_note, beat * 2.5, 'bass', rng), base, 0.19)
        if name != 'piano':
            add(voice(bass_note + 7, beat * 1.65, 'bass', rng), base + 2.5, 0.10)
        for i, note in enumerate(chord):
            add(voice(note + 12, beat * 5.0, 'pad', rng), base, 0.014 if name == 'salon' else 0.019, (i - 1.5) * 0.30)
        if name == 'salon':
            arp = [0, 2, 1, 3, 2, 1, 3, 2]
            for step, index in enumerate(arp):
                add(voice(chord[index] + 12, beat * 1.3, kind, rng), base + step * 0.5,
                    0.12 if step % 2 == 0 else 0.084, -0.28 + index * 0.12)
        elif name == 'piano':
            for step, index in enumerate([0, 2, 1, 3]):
                add(voice(chord[index] + 12, beat * 3.0, kind, rng), base + step * 0.9,
                    0.11 if step == 0 else 0.075, -0.24 + step * 0.13)
        else:
            for onset in [0.0, 1.75, 3.0]:
                for index, note in enumerate(chord):
                    add(voice(note + 12, beat * 2.3, kind, rng), base + onset + index * 0.025,
                        0.056, (index - 1.5) * 0.16)
        phrase = melody[bar % 8]
        for index, (onset, note) in enumerate(phrase):
            # Answer phrase with one small register change; always inside the harmony.
            played_note = note + (12 if name == 'piano' and bar in [4, 12] else 0)
            if name == 'chill' and bar % 2:
                onset += 0.13
            gain = {'salon': 0.17, 'piano': 0.14, 'chill': 0.12}[name]
            add(voice(played_note, beat * (2.1 if name == 'piano' else 1.35),
                      'piano' if name == 'piano' else kind, rng), base + onset, gain,
                0.06 + 0.08 * math.sin(bar + index))
        if name != 'piano':
            for onset in [0.0, 2.0]:
                add(percussion('kick', rng), base + onset, 0.095 if name == 'chill' else 0.055)
            for onset in [1.0, 3.0]:
                add(percussion('brush', rng), base + onset, 0.050 if name == 'chill' else 0.023, 0.18)
            for step in range(8):
                add(percussion('shaker', rng), base + step * 0.5 + (0.025 if step % 2 else 0),
                    0.016 if step % 2 else 0.009, -0.22)

    # Periodic room reflections: np.roll deliberately preserves continuous loop tails.
    dry = mix.copy()
    for delay, gain in [(0.071, 0.13), (0.113, 0.10), (0.181, 0.075), (0.293, 0.055), (0.419, 0.035)]:
        reflection = np.roll(dry[:, ::-1], round(delay * RATE), axis=0)
        mix += gain * reflection
    # Warm the filter with the loop's own tail, avoiding a filter-start click.
    warmup = RATE // 10
    periodic = np.concatenate([mix[-warmup:], mix], axis=0)
    mix = sosfilt(butter(2, 10500, fs=RATE, output='sos'), periodic, axis=0)[warmup:]
    # Low cut and extremely gentle saturation remove rumble without a loudness jump.
    mix -= np.mean(mix, axis=0)
    mix = np.tanh(mix * 1.25) / 1.25
    rms = float(np.sqrt(np.mean(mix ** 2)))
    peak = float(np.max(np.abs(mix)))
    mix *= min(0.1413 / max(rms, 1e-9), 0.87 / max(peak, 1e-9))
    wav = wav_dir / f'{name}.wav'
    with wave.open(str(wav), 'wb') as stream:
        stream.setnchannels(2)
        stream.setsampwidth(2)
        stream.setframerate(RATE)
        stream.writeframes((np.clip(mix, -1, 1) * 32767).astype('<i2').tobytes())
    output = output_dir / f'{name}.ogg'
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(wav),
                    '-c:a', 'libvorbis', '-q:a', '2', '-metadata', 'artist=Rami Salon 3D',
                    '-metadata', f'title={name.capitalize()} — composition originale',
                    '-metadata', 'license=CC0 1.0 Universal', str(output)], check=True)
    return {'file': output.name, 'seconds': count / RATE, 'bytes': output.stat().st_size,
            'peak_dbfs': round(20 * math.log10(float(np.max(np.abs(mix)))), 2),
            'rms_dbfs': round(20 * math.log10(float(np.sqrt(np.mean(mix ** 2)))), 2)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('--wav-dir', type=Path, default=Path(tempfile.gettempdir()) / 'rami-original-music')
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.wav_dir.mkdir(parents=True, exist_ok=True)
    stats = [compose('salon', 80, 'guitar', 3107, args.wav_dir, args.output_dir),
             compose('piano', 72, 'piano', 4109, args.wav_dir, args.output_dir),
             compose('chill', 84, 'rhodes', 5113, args.wav_dir, args.output_dir)]
    print(json.dumps(stats, indent=2))


if __name__ == '__main__':
    main()
