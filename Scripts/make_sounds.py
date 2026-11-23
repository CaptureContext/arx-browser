#!/usr/bin/env python3
"""Synthesises Arx's sound feedback (DEV-1256). Standard library only.

Usage: python3 Scripts/make_sounds.py [output directory]

Writes `capture.wav`, `done.wav` and `could-not.wav`, by default into SoundFeedbackClient's
resources (`Packages/services/Sources/SoundFeedbackClient/Resources/`), which the app bundles.

Every sound is built from one voice, a soft struck bar: a sine fundamental, a quiet
inharmonic partial at 2.76 times its pitch that dies three times faster, and a few
milliseconds of filtered noise for the strike. Pitches come from one chord (D, A),
so any two sounds heard close together agree. The output is deterministic: the noise
comes from a seeded generator, so the files are the same on every run.
"""

import math
import os
import random
import struct
import sys
import wave

RATE = 48_000
A4, A5, D6 = 440.0, 880.0, 1174.66


def db(value):
    return 10 ** (value / 20)


def silence(seconds):
    return [0.0] * int(RATE * seconds)


def mix(into, samples, at=0.0, gain=1.0):
    start = int(RATE * at)
    if len(into) < start + len(samples):
        into.extend([0.0] * (start + len(samples) - len(into)))
    for index, sample in enumerate(samples):
        into[start + index] += sample * gain
    return into


def attack(samples, seconds=0.003):
    """A raised-cosine fade in, so no sound starts with a click."""
    count = min(len(samples), int(RATE * seconds))
    for index in range(count):
        samples[index] *= 0.5 - 0.5 * math.cos(math.pi * index / count)
    return samples


def release(samples, seconds=0.012):
    count = min(len(samples), int(RATE * seconds))
    for index in range(count):
        samples[-1 - index] *= 0.5 - 0.5 * math.cos(math.pi * index / count)
    return samples


def bar(pitch, decay, brightness=0.18, length=None):
    """The family's voice. `decay` is the time the fundamental takes to fall by 1/e."""
    length = length or decay * 5
    samples, phase, upper = [], 0.0, 0.0
    for index in range(int(RATE * length)):
        time = index / RATE
        phase += 2 * math.pi * pitch / RATE
        upper += 2 * math.pi * pitch * 2.76 / RATE
        samples.append(
            math.sin(phase) * math.exp(-time / decay)
            + brightness * math.sin(upper) * math.exp(-time / (decay / 3))
        )
    return release(attack(samples))


def strike(center, decay, seed):
    """A few milliseconds of band-passed noise: the touch at the start of a note."""
    generator = random.Random(seed)
    omega = 2 * math.pi * center / RATE
    alpha = math.sin(omega) / (2 * 1.4)
    b0, b2, a0, a1, a2 = alpha, -alpha, 1 + alpha, -2 * math.cos(omega), 1 - alpha
    x1 = x2 = y1 = y2 = 0.0
    samples = []
    for index in range(int(RATE * decay * 6)):
        x0 = generator.uniform(-1, 1)
        y0 = (b0 * x0 + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2, x1, y2, y1 = x1, x0, y1, y0
        samples.append(y0 * math.exp(-index / RATE / decay))
    return release(attack(samples, 0.001), 0.004)


def finish(samples, peak_db):
    samples = samples + silence(0.02)
    peak = max(abs(sample) for sample in samples)
    return [sample / peak * db(peak_db) for sample in samples]


def capture():
    """Capture taken: two soft touches and a short high note. Not a camera imitation."""
    out = []
    mix(out, strike(3200, 0.004, seed=1), at=0.0, gain=0.9)
    mix(out, strike(2100, 0.007, seed=2), at=0.062, gain=0.6)
    mix(out, bar(D6, 0.045, brightness=0.12), at=0.062, gain=0.55)
    return finish(out, -14)


def done():
    """Download finished: two notes rising a fourth, the second ringing a little longer."""
    out = []
    mix(out, strike(2600, 0.003, seed=3), at=0.0, gain=0.25)
    mix(out, bar(A5, 0.075), at=0.0, gain=0.8)
    mix(out, bar(D6, 0.120), at=0.105, gain=1.0)
    return finish(out, -12)


def could_not():
    """Something didn't happen: the same low note twice, dull, with no falling 'error' tune."""
    out = []
    mix(out, strike(1200, 0.004, seed=4), at=0.0, gain=0.3)
    mix(out, bar(A4, 0.050, brightness=0.06), at=0.0, gain=1.0)
    mix(out, bar(A4, 0.060, brightness=0.06), at=0.095, gain=0.8)
    return finish(out, -13)


SOUNDS = {
    "capture": capture,
    "done": done,
    "could-not": could_not,
}

RESOURCES = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Packages", "services", "Sources", "SoundFeedbackClient", "Resources",
)


def write(path, samples):
    with wave.open(path, "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(RATE)
        file.writeframes(b"".join(struct.pack("<h", round(sample * 32767)) for sample in samples))


def main():
    directory = sys.argv[1] if len(sys.argv) > 1 else RESOURCES
    os.makedirs(directory, exist_ok=True)
    for name, make in SOUNDS.items():
        samples = make()
        write(os.path.join(directory, f"{name}.wav"), samples)
        peak = 20 * math.log10(max(abs(sample) for sample in samples))
        print(f"{name}.wav  {len(samples) / RATE * 1000:.0f} ms  peak {peak:.1f} dBFS")


if __name__ == "__main__":
    main()
