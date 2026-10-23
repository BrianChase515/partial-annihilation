#!/usr/bin/env python3
"""Synthesize the combat sound effects for Partial Annihilation (no samples, all original).
Writes short mono .ogg files to assets/sfx/, several variations of each so repeats don't
sound mechanical. Needs numpy, scipy, ffmpeg.   Run: python3 tools/sfx.py"""
import os, subprocess, tempfile
import numpy as np
from scipy import signal
from scipy.io import wavfile

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "sfx")


def t_axis(dur):
    return np.arange(int(dur * SR)) / SR


def noise(n, rng):
    return rng.uniform(-1, 1, n)


def lp(x, hz, order=2):
    b, a = signal.butter(order, min(hz, SR / 2 - 100) / (SR / 2), "low")
    return signal.lfilter(b, a, x)


def hp(x, hz, order=2):
    b, a = signal.butter(order, hz / (SR / 2), "high")
    return signal.lfilter(b, a, x)


def bp(x, lo, hi, order=2):
    b, a = signal.butter(order, [lo / (SR / 2), hi / (SR / 2)], "band")
    return signal.lfilter(b, a, x)


def env_exp(t, k, attack=0.002):
    return np.minimum(1, t / attack) * np.exp(-t * k)


def sweep(t, f0, f1, k):
    """sine whose frequency glides from f0 to f1 with rate k"""
    f = f1 + (f0 - f1) * np.exp(-t * k)
    return np.sin(2 * np.pi * np.cumsum(f) / SR)


def room(x, rng, dur=0.6, wet=0.25, damp=3000):
    """cheap outdoor reverb: convolve with decaying filtered noise"""
    ir_t = t_axis(dur)
    ir = lp(noise(len(ir_t), rng), damp) * np.exp(-ir_t * 7)
    ir[0] = 0
    ir /= np.max(np.abs(ir)) + 1e-9
    y = signal.fftconvolve(x, ir)[: len(x) + len(ir_t)]
    out = np.zeros(len(y))
    out[: len(x)] += x
    return out + y / (np.max(np.abs(y)) + 1e-9) * np.max(np.abs(x)) * wet


def finish(x, peak):
    x = x - np.mean(x)
    # fade the tail to silence and trim trailing quiet
    nz = np.where(np.abs(x) > np.max(np.abs(x)) * 0.004)[0]
    x = x[: (nz[-1] + 1) if len(nz) else len(x)]
    fade = min(len(x), int(0.02 * SR))
    x[-fade:] *= np.linspace(1, 0, fade)
    return x / (np.max(np.abs(x)) + 1e-9) * peak


def save(name, x, peak=0.9):
    x = finish(x, peak)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        tmp = f.name
    wavfile.write(tmp, SR, (np.clip(x, -1, 1) * 32767).astype(np.int16))
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", tmp, "-ac", "1", "-c:a", "libvorbis", "-q:a", "4",
                    os.path.join(OUT, name + ".ogg")], check=True)
    os.unlink(tmp)
    print(f"{name:16s} {len(x) / SR:.2f}s")


# ------------------------------------------------------------------ the sounds
def rifle(rng):
    """small arms: a sharp crack with a little body, sometimes a double tap"""
    t = t_axis(0.25)
    shots = 2 if rng.random() < 0.5 else 1
    x = np.zeros(len(t))
    for k in range(shots):
        o = int(k * 0.07 * SR)
        tt = t[: len(t) - o]
        crack = hp(noise(len(tt), rng), 1800) * env_exp(tt, 90, 0.0005)
        body = bp(noise(len(tt), rng), 300, 1400) * env_exp(tt, 45)
        x[o:] += crack * 0.8 + body * 0.7
    return room(x, rng, 0.3, 0.18)


def blaster(rng):
    """medium energy gun: a short descending 'pew' wrapped in noise"""
    t = t_axis(0.3)
    f0 = rng.uniform(1300, 1700)
    tone = sweep(t, f0, f0 * 0.28, 22) * env_exp(t, 18, 0.001)
    fizz = bp(noise(len(t), rng), 1500, 6000) * env_exp(t, 40)
    thump = np.sin(2 * np.pi * 110 * t) * env_exp(t, 30)
    return room(tone * 0.55 + fizz * 0.35 + thump * 0.4, rng, 0.35, 0.2)


def heavy(rng):
    """heavy cannon: sub thump, crack, rolling tail"""
    t = t_axis(1.1)
    sub = sweep(t, 140, 45, 14) * env_exp(t, 6, 0.002)
    crack = hp(noise(len(t), rng), 900) * env_exp(t, 35, 0.0008)
    roll = lp(noise(len(t), rng), 500) * env_exp(t, 4.5, 0.02)
    return room(sub * 1.0 + crack * 0.6 + roll * 0.8, rng, 0.9, 0.3, 1800)


def artillery_fire(rng):
    """artillery: a deep distant boom with a long thunder-like tail"""
    t = t_axis(2.2)
    sub = sweep(t, 90, 32, 9) * env_exp(t, 3.5, 0.004)
    blast = lp(noise(len(t), rng), 700) * env_exp(t, 9, 0.002)
    tail = lp(noise(len(t), rng), 260, 3) * env_exp(t, 1.8, 0.08)
    # a few echoes off terrain
    x = sub * 1.0 + blast * 0.7 + tail * 1.2
    for d, g in ((0.18, 0.35), (0.41, 0.22), (0.77, 0.12)):
        o = int(d * SR)
        x[o:] += lp(x[: len(x) - o], 400) * g
    return room(x, rng, 1.2, 0.35, 900)


def impact(rng):
    """shell landing: crunch + dirt + low thud"""
    t = t_axis(0.9)
    thud = sweep(t, 110, 40, 16) * env_exp(t, 9)
    crunch = bp(noise(len(t), rng), 400, 3500) * env_exp(t, 14, 0.001)
    debris = hp(noise(len(t), rng), 2500) * env_exp(t, 9, 0.03) * (rng.uniform(0.3, 0.6))
    return room(thud * 0.9 + crunch * 0.8 + debris * 0.4, rng, 0.6, 0.25, 1600)


def flak(rng):
    """anti-air: a tight pop with a high fizz"""
    t = t_axis(0.35)
    pop = bp(noise(len(t), rng), 600, 4000) * env_exp(t, 30, 0.0006)
    ring = np.sin(2 * np.pi * rng.uniform(2200, 2800) * t) * env_exp(t, 45)
    return room(pop * 0.9 + ring * 0.25, rng, 0.4, 0.25)


def torpedo(rng):
    """torpedo launch: muffled whoosh with bubbles"""
    t = t_axis(0.9)
    whoosh = lp(noise(len(t), rng), 900) * np.sin(np.pi * np.minimum(1, t / 0.9)) ** 1.5
    bub = np.zeros(len(t))
    for _ in range(14):
        s = int(rng.uniform(0, 0.7) * SR)
        f = rng.uniform(300, 900)
        tt = t[: len(t) - s]
        bub[s:] += np.sin(2 * np.pi * (f + 400 * tt) * tt) * np.exp(-tt * 40) * 0.4
    return lp(whoosh * 0.8 + bub, 2500)


def boom_small(rng):
    """small unit destroyed"""
    t = t_axis(1.0)
    sub = sweep(t, 120, 50, 12) * env_exp(t, 7)
    blast = lp(noise(len(t), rng), 1500) * env_exp(t, 8, 0.002)
    metal = bp(noise(len(t), rng), 2000, 5000) * env_exp(t, 18, 0.01) * 0.3
    return room(sub * 0.9 + blast + metal, rng, 0.7, 0.3, 1500)


def boom_big(rng):
    """building / Commander destroyed: big layered blast with a long rumble"""
    t = t_axis(2.6)
    sub = sweep(t, 80, 28, 5) * env_exp(t, 2.2, 0.005)
    blast = lp(noise(len(t), rng), 1100) * env_exp(t, 4, 0.003)
    rumble = lp(noise(len(t), rng), 180, 3) * env_exp(t, 1.4, 0.1)
    debris = np.zeros(len(t))
    for _ in range(10):
        s = int(rng.uniform(0.15, 1.4) * SR)
        tt = t[: len(t) - s]
        debris[s:] += bp(noise(len(tt), rng), 1500, 6000) * np.exp(-tt * 30) * rng.uniform(0.1, 0.3)
    return room(sub * 1.1 + blast * 0.9 + rumble * 1.4 + debris, rng, 1.4, 0.35, 1000)


def skill(rng):
    """Arena skill cast: a rising shimmer into a soft hit"""
    t = t_axis(0.7)
    rise = sweep(t, 300, 1400, -3) if False else np.sin(2 * np.pi * np.cumsum(300 + 1500 * np.minimum(1, t / 0.25)) / SR)
    rise *= np.minimum(1, t / 0.02) * np.exp(-np.maximum(0, t - 0.25) * 9)
    shimmer = bp(noise(len(t), rng), 3000, 9000) * np.exp(-t * 6) * 0.25
    hit = sweep(t, 160, 60, 12) * np.exp(-np.maximum(0, t - 0.22) * 10) * (t > 0.22)
    return room(rise * 0.35 + shimmer + hit * 0.8, rng, 0.6, 0.3, 4000)


def punch(rng):
    """melee blow: a meaty low thump with a short slap on top"""
    t = t_axis(0.3)
    thump = sweep(t, rng.uniform(150, 190), 55, 30) * env_exp(t, 22, 0.001)
    slap = bp(noise(len(t), rng), 900, 3500) * env_exp(t, 70, 0.0005)
    swish = hp(noise(len(t), rng), 3000) * np.exp(-((t - 0.0) / 0.02) ** 2) * 0.2
    return room(thump * 1.0 + slap * 0.55 + swish, rng, 0.25, 0.12)


def main():
    os.makedirs(OUT, exist_ok=True)
    rng = np.random.default_rng(515)
    plan = [("rifle", rifle, 3, 0.8), ("blaster", blaster, 3, 0.8), ("heavy", heavy, 2, 0.95),
            ("artillery", artillery_fire, 2, 0.95), ("impact", impact, 3, 0.9), ("flak", flak, 2, 0.75),
            ("torpedo", torpedo, 1, 0.8), ("boom", boom_small, 3, 0.95), ("bigboom", boom_big, 2, 1.0),
            ("skill", skill, 2, 0.8), ("punch", punch, 3, 0.7)]
    for name, fn, n, peak in plan:
        for i in range(1, n + 1):
            save(f"{name}{i}", fn(rng), peak)


if __name__ == "__main__":
    main()
