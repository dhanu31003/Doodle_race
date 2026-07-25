#!/usr/bin/env python3
"""Reproducibly synthesize RaceGlyph's original music and sound cues.

This generator uses only Python's standard library and mathematical waveforms.
No recorded performances, sample packs, external melodies, or third-party audio
are inputs. Run with ``--check`` to verify that committed WAVs and their manifest
still match this source exactly.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import random
import struct
import wave
from pathlib import Path
from typing import Callable


SAMPLE_RATE = 22_050
PCM_PEAK = 32_767
GENERATOR_VERSION = "2"
PROJECT_ROOT = Path(__file__).resolve().parents[2]
OUTPUT_DIR = PROJECT_ROOT / "assets" / "final" / "audio"
MANIFEST_PATH = OUTPUT_DIR / "original-audio-manifest.json"

Waveform = Callable[[float], float]


def sine(phase: float) -> float:
    return math.sin(phase)


def triangle(phase: float) -> float:
    return (2.0 / math.pi) * math.asin(math.sin(phase))


def soft_square(phase: float) -> float:
    return math.tanh(2.4 * math.sin(phase))


def make_buffer(duration: float) -> list[float]:
    return [0.0] * int(round(duration * SAMPLE_RATE))


def envelope(t: float, duration: float, attack: float, release: float) -> float:
    if duration <= 0.0 or t < 0.0 or t >= duration:
        return 0.0
    attack_gain = min(1.0, t / max(attack, 1.0 / SAMPLE_RATE))
    release_gain = min(1.0, (duration - t) / max(release, 1.0 / SAMPLE_RATE))
    return max(0.0, min(attack_gain, release_gain))


def add_tone(
    samples: list[float],
    start: float,
    duration: float,
    frequency: float,
    amplitude: float,
    waveform: Waveform = sine,
    *,
    frequency_end: float | None = None,
    attack: float = 0.008,
    release: float = 0.06,
    vibrato_hz: float = 0.0,
    vibrato_depth: float = 0.0,
) -> None:
    first = max(0, int(round(start * SAMPLE_RATE)))
    count = int(round(duration * SAMPLE_RATE))
    end = min(len(samples), first + count)
    final_frequency = frequency if frequency_end is None else frequency_end
    for frame in range(first, end):
        t = (frame - first) / SAMPLE_RATE
        progress = t / max(duration, 1.0 / SAMPLE_RATE)
        sweep = frequency + (final_frequency - frequency) * progress
        base_phase = 2.0 * math.pi * (
            frequency * t + 0.5 * (final_frequency - frequency) * t * progress
        )
        modulation = 0.0
        if vibrato_hz > 0.0 and vibrato_depth > 0.0:
            modulation = vibrato_depth * math.sin(2.0 * math.pi * vibrato_hz * t)
        phase = base_phase + (2.0 * math.pi * modulation * sweep / SAMPLE_RATE)
        samples[frame] += amplitude * envelope(t, duration, attack, release) * waveform(phase)


def add_noise(
    samples: list[float],
    start: float,
    duration: float,
    amplitude: float,
    seed: int,
    *,
    attack: float = 0.003,
    release: float = 0.08,
    smooth: float = 0.0,
) -> None:
    rng = random.Random(seed)
    first = max(0, int(round(start * SAMPLE_RATE)))
    count = int(round(duration * SAMPLE_RATE))
    end = min(len(samples), first + count)
    filtered = 0.0
    smoothing = max(0.0, min(smooth, 0.995))
    for frame in range(first, end):
        t = (frame - first) / SAMPLE_RATE
        white = rng.uniform(-1.0, 1.0)
        filtered = smoothing * filtered + (1.0 - smoothing) * white
        samples[frame] += amplitude * envelope(t, duration, attack, release) * filtered


def add_kick(samples: list[float], start: float, amplitude: float = 0.28) -> None:
    add_tone(
        samples,
        start,
        0.18,
        112.0,
        amplitude,
        sine,
        frequency_end=42.0,
        attack=0.002,
        release=0.14,
    )


def menu_loop() -> list[float]:
    samples = make_buffer(8.0)
    chords = (
        (130.81, 155.56, 196.00),
        (116.54, 146.83, 174.61),
        (103.83, 130.81, 155.56),
        (116.54, 146.83, 196.00),
    )
    for bar, chord in enumerate(chords):
        start = bar * 2.0
        for voice, frequency in enumerate(chord):
            add_tone(
                samples,
                start,
                1.94,
                frequency,
                0.055 - voice * 0.007,
                triangle if voice == 0 else sine,
                attack=0.28,
                release=0.35,
                vibrato_hz=0.18 + voice * 0.03,
                vibrato_depth=0.015,
            )
        for step, multiplier in enumerate((2.0, 2.5, 3.0, 2.5)):
            add_tone(
                samples,
                start + step * 0.5,
                0.28,
                chord[0] * multiplier,
                0.07,
                sine,
                attack=0.012,
                release=0.20,
            )
    return samples


def race_loop() -> list[float]:
    samples = make_buffer(8.0)
    roots = (65.41, 73.42, 58.27, 77.78)
    for bar, root in enumerate(roots):
        bar_start = bar * 2.0
        for step in range(8):
            beat = bar_start + step * 0.25
            if step in (0, 3, 4, 6):
                add_kick(samples, beat, 0.25 if step in (0, 4) else 0.18)
            add_tone(
                samples,
                beat,
                0.19,
                root * (2.0 if step in (3, 7) else 1.0),
                0.12,
                soft_square,
                frequency_end=root * (1.96 if step in (3, 7) else 0.94),
                attack=0.004,
                release=0.10,
            )
            if step % 2 == 1:
                add_noise(samples, beat, 0.075, 0.10, 4000 + bar * 10 + step, release=0.055)
        add_tone(samples, bar_start, 1.92, root * 2.0, 0.035, triangle, attack=0.08, release=0.16)
    return samples


def engine_loop() -> list[float]:
    """Seamless fictional open-wheel engine bed, pitch-driven at runtime."""
    duration = 2.0
    samples = make_buffer(duration)
    base_frequency = 110.0  # Integer cycles over two seconds: seamless loop.
    for frame in range(len(samples)):
        t = frame / SAMPLE_RATE
        phase = 2.0 * math.pi * base_frequency * t
        combustion = (
            0.19 * triangle(phase)
            + 0.11 * soft_square(phase * 2.0 + 0.12)
            + 0.065 * sine(phase * 3.0 + 0.4)
            + 0.035 * sine(phase * 5.0 + 0.7)
        )
        pulse = 0.82 + 0.18 * sine(2.0 * math.pi * 8.0 * t)
        samples[frame] = combustion * pulse
    return samples


def forest_ambience() -> list[float]:
    """Seamless night-forest air made only from periodic oscillators."""
    duration = 8.0
    samples = make_buffer(duration)
    rng = random.Random(6001)
    partials: list[tuple[float, float, float]] = []
    # Every frequency is an integer multiple of 1/duration, so the buffer loops.
    for harmonic in range(3, 43):
        amplitude = rng.uniform(0.002, 0.012) / math.sqrt(harmonic)
        phase = rng.uniform(0.0, math.tau)
        partials.append((harmonic / duration, amplitude, phase))
    for frame in range(len(samples)):
        t = frame / SAMPLE_RATE
        wind = sum(
            amplitude * math.sin(2.0 * math.pi * frequency * t + phase)
            for frequency, amplitude, phase in partials
        )
        canopy = 0.018 * sine(2.0 * math.pi * 0.25 * t) * sine(2.0 * math.pi * 43.0 * t)
        samples[frame] = wind + canopy
    return samples


def countdown() -> list[float]:
    samples = make_buffer(0.34)
    add_tone(samples, 0.0, 0.27, 620.0, 0.34, sine, attack=0.004, release=0.13)
    add_tone(samples, 0.0, 0.25, 930.0, 0.12, sine, attack=0.004, release=0.14)
    return samples


def go_cue() -> list[float]:
    samples = make_buffer(0.78)
    add_tone(samples, 0.0, 0.65, 520.0, 0.24, triangle, frequency_end=880.0, attack=0.006, release=0.19)
    add_tone(samples, 0.08, 0.62, 780.0, 0.17, sine, frequency_end=1320.0, attack=0.01, release=0.22)
    add_noise(samples, 0.0, 0.3, 0.08, 5101, release=0.23, smooth=0.55)
    return samples


def click() -> list[float]:
    samples = make_buffer(0.085)
    add_tone(samples, 0.0, 0.055, 1180.0, 0.25, triangle, frequency_end=820.0, attack=0.001, release=0.043)
    add_noise(samples, 0.0, 0.025, 0.07, 5201, release=0.02)
    return samples


def confirm() -> list[float]:
    samples = make_buffer(0.42)
    for delay, frequency in ((0.0, 523.25), (0.075, 659.25), (0.15, 783.99)):
        add_tone(samples, delay, 0.24, frequency, 0.20, sine, attack=0.004, release=0.15)
    return samples


def error() -> list[float]:
    samples = make_buffer(0.48)
    add_tone(samples, 0.0, 0.20, 311.13, 0.21, soft_square, frequency_end=277.18, attack=0.004, release=0.10)
    add_tone(samples, 0.20, 0.24, 261.63, 0.24, soft_square, frequency_end=196.00, attack=0.004, release=0.13)
    return samples


def boost() -> list[float]:
    samples = make_buffer(0.92)
    add_noise(samples, 0.0, 0.88, 0.34, 5401, attack=0.07, release=0.22, smooth=0.74)
    add_tone(samples, 0.0, 0.82, 74.0, 0.20, triangle, frequency_end=184.0, attack=0.05, release=0.24)
    add_tone(samples, 0.16, 0.62, 310.0, 0.08, sine, frequency_end=680.0, attack=0.04, release=0.25)
    return samples


def skid() -> list[float]:
    samples = make_buffer(0.68)
    add_noise(samples, 0.0, 0.64, 0.44, 5501, attack=0.015, release=0.18, smooth=0.38)
    add_tone(samples, 0.0, 0.61, 1140.0, 0.07, sine, frequency_end=720.0, attack=0.02, release=0.20, vibrato_hz=23.0, vibrato_depth=0.10)
    return samples


def collision() -> list[float]:
    samples = make_buffer(0.34)
    add_noise(samples, 0.0, 0.26, 0.42, 5601, attack=0.001, release=0.22, smooth=0.63)
    add_tone(samples, 0.0, 0.30, 96.0, 0.40, sine, frequency_end=38.0, attack=0.001, release=0.25)
    add_tone(samples, 0.01, 0.16, 420.0, 0.13, soft_square, frequency_end=150.0, attack=0.001, release=0.12)
    return samples


def lap() -> list[float]:
    samples = make_buffer(0.76)
    for delay, frequency in ((0.0, 659.25), (0.12, 783.99), (0.24, 987.77), (0.38, 1318.51)):
        add_tone(samples, delay, 0.28, frequency, 0.20, sine, attack=0.003, release=0.16)
    return samples


def finish() -> list[float]:
    samples = make_buffer(1.9)
    melody = ((0.0, 523.25), (0.22, 659.25), (0.44, 783.99), (0.70, 1046.50), (1.02, 783.99), (1.24, 1046.50))
    for delay, frequency in melody:
        add_tone(samples, delay, 0.42, frequency, 0.18, triangle, attack=0.005, release=0.20)
        add_tone(samples, delay, 0.38, frequency * 1.5, 0.07, sine, attack=0.008, release=0.19)
    add_tone(samples, 1.24, 0.62, 523.25, 0.12, sine, attack=0.02, release=0.35)
    return samples


CUES: dict[str, tuple[str, Callable[[], list[float]], str, bool]] = {
    "menu_loop": ("music", menu_loop, "Ambient menu loop", True),
    "race_loop": ("music", race_loop, "Rhythmic race loop", True),
    "engine_loop": ("engine", engine_loop, "Speed-reactive fictional open-wheel engine loop", True),
    "forest_ambience": ("ambience", forest_ambience, "Night forest circuit ambience", True),
    "countdown": ("sfx", countdown, "Race countdown pulse", False),
    "go": ("sfx", go_cue, "Race start lift", False),
    "click": ("sfx", click, "Interface click", False),
    "confirm": ("sfx", confirm, "Positive interface confirmation", False),
    "error": ("sfx", error, "Validation or interface error", False),
    "boost": ("sfx", boost, "Vehicle boost whoosh", False),
    "skid": ("sfx", skid, "Tyre skid texture", False),
    "collision": ("sfx", collision, "Vehicle impact", False),
    "lap": ("sfx", lap, "Lap completion arpeggio", False),
    "finish": ("sfx", finish, "Race finish fanfare", False),
}


def pcm_wav(samples: list[float]) -> bytes:
    peak = max((abs(value) for value in samples), default=0.0)
    gain = min(1.0, 0.92 / peak) if peak > 0.0 else 1.0
    frames = bytearray()
    for value in samples:
        shaped = math.tanh(value * gain * 1.05) / math.tanh(1.05)
        integer = int(round(max(-1.0, min(1.0, shaped)) * PCM_PEAK))
        frames.extend(struct.pack("<h", integer))
    output = io.BytesIO()
    with wave.open(output, "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(SAMPLE_RATE)
        writer.writeframes(bytes(frames))
    return output.getvalue()


def build_outputs() -> tuple[dict[str, bytes], dict[str, object]]:
    generated: dict[str, bytes] = {}
    entries: list[dict[str, object]] = []
    for cue_id, (category, synth, description, loops) in CUES.items():
        samples = synth()
        encoded = pcm_wav(samples)
        filename = f"{cue_id}.wav"
        generated[filename] = encoded
        entries.append(
            {
                "cue_id": cue_id,
                "path": f"assets/final/audio/{filename}",
                "category": category,
                "description": description,
                "loops_at_runtime": loops,
                "sample_rate_hz": SAMPLE_RATE,
                "channels": 1,
                "sample_format": "signed 16-bit PCM little-endian",
                "frames": len(samples),
                "duration_seconds": round(len(samples) / SAMPLE_RATE, 6),
                "sha256": hashlib.sha256(encoded).hexdigest(),
            }
        )
    manifest: dict[str, object] = {
        "schema_version": 1,
        "project": "RaceGlyph",
        "generator_version": GENERATOR_VERSION,
        "generator": "tools/audio/generate_original_audio.py",
        "provenance": "Original procedural synthesis from mathematical oscillators and seeded noise; no external audio, melodies, recordings, or sample libraries were used.",
        "license_id": "LicenseRef-RaceGlyph-Original",
        "license_summary": "Original RaceGlyph project audio, royalty-free for RaceGlyph project distribution and promotion.",
        "determinism": {
            "python_dependencies": "standard library only",
            "sample_rate_hz": SAMPLE_RATE,
            "noise_randomness": "local fixed integer seeds per cue",
        },
        "assets": entries,
    }
    return generated, manifest


def encoded_manifest(manifest: dict[str, object]) -> bytes:
    return (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")


def check_outputs(generated: dict[str, bytes], manifest: dict[str, object]) -> int:
    expected_names = set(generated) | {MANIFEST_PATH.name}
    actual_names = {path.name for path in OUTPUT_DIR.glob("*") if path.is_file() and path.suffix != ".import"}
    failures: list[str] = []
    for filename, expected in generated.items():
        path = OUTPUT_DIR / filename
        if not path.is_file():
            failures.append(f"missing {path.relative_to(PROJECT_ROOT)}")
        elif path.read_bytes() != expected:
            failures.append(f"content differs: {path.relative_to(PROJECT_ROOT)}")
    expected_manifest = encoded_manifest(manifest)
    if not MANIFEST_PATH.is_file():
        failures.append(f"missing {MANIFEST_PATH.relative_to(PROJECT_ROOT)}")
    elif MANIFEST_PATH.read_bytes() != expected_manifest:
        failures.append(f"content differs: {MANIFEST_PATH.relative_to(PROJECT_ROOT)}")
    for extra in sorted(actual_names - expected_names):
        failures.append(f"unexpected generated output: assets/final/audio/{extra}")
    if failures:
        for failure in failures:
            print(f"ERROR: {failure}")
        return 1
    print(f"RaceGlyph audio check passed: {len(generated)} deterministic WAV assets")
    return 0


def write_outputs(generated: dict[str, bytes], manifest: dict[str, object]) -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for filename, encoded in generated.items():
        (OUTPUT_DIR / filename).write_bytes(encoded)
    MANIFEST_PATH.write_bytes(encoded_manifest(manifest))
    print(f"Generated {len(generated)} original RaceGlyph WAV assets in {OUTPUT_DIR}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify committed audio without rewriting it")
    arguments = parser.parse_args()
    generated, manifest = build_outputs()
    if arguments.check:
        return check_outputs(generated, manifest)
    write_outputs(generated, manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
