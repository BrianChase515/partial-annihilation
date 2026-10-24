#!/usr/bin/env python3
"""Mix the soundtrack for a recorded trailer: the score (one suite's three stems, mixed by how
heavy the fighting on screen is) plus every sound the game made while the frames were captured
(tools/trailer.lua logs them to trailer_<mode>_audio.txt).

  python3 tools/trailer_audio.py <audio.txt> <frames> <fps> <suite tag, e.g. _n> <out.wav>"""
import os, sys, subprocess, random
import numpy as np

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SR = 44100
VARIANTS = {"rifle": 3, "blaster": 3, "heavy": 2, "artillery": 2, "impact": 3, "flak": 2, "torpedo": 1,
            "boom": 3, "bigboom": 2, "skill": 2, "punch": 3}
_cache = {}


def load(path):
    if path not in _cache:
        raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"],
                             check=True, stdout=subprocess.PIPE).stdout
        _cache[path] = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).copy()
    return _cache[path]


def repitch(x, f):
    if abs(f - 1) < 1e-3:
        return x
    n = int(len(x) / f)
    idx = np.linspace(0, len(x) - 1, n)
    return np.stack([np.interp(idx, np.arange(len(x)), x[:, c]) for c in (0, 1)], axis=1).astype(np.float32)


def smooth(e0, e1, v):
    t = np.clip((v - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def main():
    log, frames, fps, suite, out = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4], sys.argv[5]
    dur = frames / fps + 1.0
    n = int(dur * SR)
    mix = np.zeros((n, 2), np.float32)
    rng = random.Random(5)
    inten = np.zeros(frames + 2, np.float32)
    events = []
    for line in open(log):
        p = line.rstrip("\n").split("\t")
        if p[0] == "int":
            i = int(p[1])
            if i < len(inten): inten[i] = float(p[2])
        else:
            events.append((p[0], p[1], float(p[2]), float(p[3]), float(p[4]), float(p[5]), float(p[6])))
    # the score: ambient always, tension and combat rising with the fighting (smoothed over ~1.5 s)
    k = np.zeros_like(inten)
    a = 1 - np.exp(-1 / (fps * 1.5))
    for i in range(1, len(inten)):
        k[i] = k[i - 1] + (max(inten[i], k[i - 1] * 0.98) - k[i - 1]) * a * (3 if inten[i] > k[i - 1] else 1)
    t_frames = np.arange(len(k)) / fps
    t = np.arange(n) / SR
    kk = np.interp(t, t_frames, k)
    gains = {"ambient": 0.75 + 0.25 * (1 - kk), "tension": smooth(0.05, 0.35, kk), "combat": smooth(0.3, 0.7, kk)}
    for stem, g in gains.items():
        s = load(os.path.join(ROOT, "assets", "music", f"{stem}{suite}.ogg"))
        reps = int(np.ceil(n / len(s))) + 1
        loop = np.tile(s, (reps, 1))[:n]
        mix += loop * g[:, None] * 0.55
    # the battle
    last = {}
    for kind, name, at, v, pan, pitch, gap in events:
        if kind == "sfx":
            if at - last.get(name, -99) < gap:
                continue
            last[name] = at
            path = os.path.join(ROOT, "assets", "sfx", f"{name}{rng.randint(1, VARIANTS.get(name, 1))}.ogg")
            gain = v * 0.5 * 1.6
        else:
            path = os.path.join(ROOT, "assets", "voice", f"{name}.ogg")
            gain = v * (0.95 if kind == "voice" else 0.8)
        if not os.path.exists(path):
            continue
        x = repitch(load(path), pitch * (1 + (rng.random() - 0.5) * 0.1))
        i0 = int(at * SR)
        if i0 >= n:
            continue
        x = x[: n - i0]
        th = (pan + 1) * np.pi / 4
        mix[i0:i0 + len(x), 0] += x[:, 0] * gain * np.cos(th) * 1.41
        mix[i0:i0 + len(x), 1] += x[:, 1] * gain * np.sin(th) * 1.41
    # loud but not clipped
    mix = np.tanh(mix * 1.1) * 0.95
    raw = (np.clip(mix, -1, 1) * 32767).astype(np.int16)
    tmp = out + ".raw"
    raw.tofile(tmp)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "s16le", "-ar", str(SR), "-ac", "2", "-i", tmp, out], check=True)
    os.unlink(tmp)
    print("mixed", len(events), "events into", out, "%.1fs" % dur)


if __name__ == "__main__":
    main()
