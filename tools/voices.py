#!/usr/bin/env python3
"""Render the robotic announcer lines into assets/voice/*.ogg.
Needs espeak-ng, ffmpeg, numpy, scipy.  Run from the repo root: python3 tools/voices.py"""
import os, subprocess, tempfile
import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt

LINES = {
    "under_attack":     "Warning. Base under attack.",
    "units_attacked":   "Units under attack.",
    "commander_attack": "Alert. Commander under fire.",
    "commander_low":    "Commander critical. Retreat advised.",
    "nuke_incoming":    "Warning. Nuke en route.",
    "nuke_launched":    "Nuke launched.",
    "nuke_ready":       "Nuke armed and ready.",
    "commander_level":  "Commander promoted. Upgrade available.",
    "dropship":         "Dropship approaching.",
    "drop_contact":     "Drop crew contact.",
    "drop_join":        "Reinforcements acquired.",
    "drop_hostile":     "Hostile crew deployed.",
    "alien_signal":     "Alien signal detected.",
    "alien_landed":     "Alien tech has landed.",
    "alien_claimed":    "Alien tech secured.",
    "alien_lost":       "Alien tech lost to the enemy.",
    "construction":     "Construction complete.",
    "low_metal":        "Insufficient metal.",
    "low_energy":       "Insufficient energy.",
    "enemy_eliminated": "Enemy eliminated.",
    "ally_eliminated":  "Ally eliminated.",
    "self_destruct":    "Self destruct.",
    "retreat":          "Retreating.",
    "commander_online": "Commander online. Battle commencing.",
    "victory":          "Victory.",
    "defeat":           "Defeat. Commander lost.",
    "ultimate_ready":   "Ultimate ready.",
    "cmd_down":         "Commander down. Respawning.",
    "enemy_cmd_down":   "Enemy commander destroyed.",
    "respawned":        "Commander back online.",
    "tower_lost":       "Our tower has fallen.",
    "tower_destroyed":  "Enemy tower destroyed.",
    "creeps":           "Creeps are marching.",
    "core_attack":      "Warning. Core under attack.",
}

SR = 22050
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "voice")

def robot(x, sr):
    t = np.arange(len(x)) / sr
    # ring modulation (classic robot), blended with the dry voice so it stays readable
    ring = x * np.sin(2 * np.pi * 62 * t)
    y = 0.55 * x + 0.85 * ring
    # metallic comb: short feedback-free delays
    for d, g in ((0.0045, 0.45), (0.011, 0.3)):
        n = int(d * sr)
        y[n:] += g * y[:-n]
    # light bit crush
    q = 2 ** 9
    y = 0.7 * y + 0.3 * (np.round(y * q) / q)
    sos = butter(4, [190, 5200], btype="band", fs=sr, output="sos")
    y = sosfilt(sos, y)
    # radio chirp in front, click off at the end
    bl = int(0.07 * sr)
    tb = np.arange(bl) / sr
    chirp = 0.25 * np.sin(2 * np.pi * (1500 + 900 * tb / tb[-1]) * tb) * np.hanning(bl)
    gap = np.zeros(int(0.05 * sr))
    y = np.concatenate([chirp, gap, y])
    y /= max(1e-6, np.max(np.abs(y)))
    return (y * 0.9).astype(np.float32)

def main():
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        for key, text in LINES.items():
            raw = os.path.join(td, key + ".wav")
            subprocess.run(["espeak-ng", "-v", "en-us+m3", "-s", "150", "-p", "28", "-a", "180",
                            "-w", raw, text], check=True)
            sr, x = wavfile.read(raw)
            x = x.astype(np.float32) / 32768.0
            if x.ndim > 1: x = x.mean(axis=1)
            y = robot(x, sr)
            fx = os.path.join(td, key + "_fx.wav")
            wavfile.write(fx, sr, (y * 32767).astype(np.int16))
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", fx, "-ar", str(SR), "-ac", "1",
                            "-c:a", "libvorbis", "-q:a", "3", os.path.join(OUT, key + ".ogg")], check=True)
    print("rendered", len(LINES), "lines to", OUT)

if __name__ == "__main__":
    main()
