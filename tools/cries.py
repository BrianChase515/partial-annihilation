#!/usr/bin/env python3
"""SUPERSEDED: the game now ships recorded voices (see assets/voice/CREDITS.md). Running this would overwrite
them with the old synthetic cries.

Render War is Hell battlefield cries into assets/voice/cry_*.ogg: death screams and wounded
shouts, over a crackly field-radio filter (rougher than the announcer).
Needs espeak-ng, ffmpeg, numpy, scipy.  Run from the repo root: python3 tools/cries.py"""
import os, subprocess, tempfile
import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt

DEATH = ["Aaaaaagh!", "Noooo!", "Aagh! Medic!", "Uuuurgh!", "Not like this!", "Aaah! Mom!", "Argh!", "I'm done for!"]
HURT = ["It hurts!", "I'm hit! I'm hit!", "Medic!", "Get me out of here!", "Agh! My leg!", "I'm bleeding!",
        "We're getting torn apart!", "Somebody help!"]
VOICES = ["en-us+m1", "en-us+m3", "en-us+m4", "en-us+m7", "en+m2", "en-gb+m5", "en-us+f2", "en+m6"]
SR = 22050
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "voice")

def radio(x, sr, rng):
    # strained voice through a cheap field radio: overdrive, band-limit, crackle
    y = np.tanh(x * 3.2)
    sos = butter(4, [320, 3400], btype="band", fs=sr, output="sos")
    y = sosfilt(sos, y)
    crackle = (rng.random(len(y)) < 0.002) * rng.normal(0, 0.6, len(y))
    hiss = rng.normal(0, 0.025, len(y))
    y = y + crackle + hiss
    y /= max(1e-6, np.max(np.abs(y)))
    return (y * 0.92).astype(np.float32)

def render(td, key, text, voice, speed, pitch, rng):
    raw = os.path.join(td, key + ".wav")
    subprocess.run(["espeak-ng", "-v", voice, "-s", str(speed), "-p", str(pitch), "-a", "200", "-w", raw, text], check=True)
    sr, x = wavfile.read(raw)
    x = x.astype(np.float32) / 32768.0
    if x.ndim > 1: x = x.mean(axis=1)
    y = radio(x, sr, rng)
    fx = os.path.join(td, key + "_fx.wav")
    wavfile.write(fx, sr, (y * 32767).astype(np.int16))
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", fx, "-ar", str(SR), "-ac", "1",
                    "-c:a", "libvorbis", "-q:a", "3", os.path.join(OUT, key + ".ogg")], check=True)

def main():
    os.makedirs(OUT, exist_ok=True)
    rng = np.random.default_rng(7)
    with tempfile.TemporaryDirectory() as td:
        for i, text in enumerate(DEATH, 1):
            render(td, "cry_death_%d" % i, text, VOICES[i % len(VOICES)], 175, 70 + (i * 7) % 25, rng)
        for i, text in enumerate(HURT, 1):
            render(td, "cry_hurt_%d" % i, text, VOICES[(i + 3) % len(VOICES)], 190, 55 + (i * 11) % 30, rng)
    print("rendered", len(DEATH) + len(HURT), "cries to", OUT)

if __name__ == "__main__":
    main()
