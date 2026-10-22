#!/usr/bin/env python3
"""Compose the Partial Annihilation score as MIDI and render it with FluidSynth.
Three tempo-locked 32-bar loops in D minor (ambient / tension / combat) that the game
crossfades by combat intensity, plus victory and defeat stingers.
Needs: mido, numpy, scipy, fluidsynth + FluidR3_GM.sf2, ffmpeg.   Run: python3 tools/compose.py"""
import os, subprocess, tempfile, random
import numpy as np
import mido
from scipy.io import wavfile

BPM, TPB, BARS = 88, 480, 32
SF2 = "/usr/share/sounds/sf2/FluidR3_GM.sf2"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "music")
SR = 44100
rng = random.Random(7)

N = {"C": 0, "C#": 1, "Db": 1, "D": 2, "Eb": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "Ab": 8, "A": 9, "Bb": 10, "B": 11}
def n(s):  # "D5" -> midi
    name, octv = s[:-1], int(s[-1])
    return 12 * (octv + 1) + N[name]

# chord per bar: (root name, triad pcs)
CH = {"Dm": ("D", [2, 5, 9]), "Bb": ("Bb", [10, 2, 5]), "F": ("F", [5, 9, 0]), "C": ("C", [0, 4, 7]),
      "Gm": ("G", [7, 10, 2]), "A": ("A", [9, 1, 4]), "A7": ("A", [9, 1, 4, 7])}
PROG = ["Dm", "Bb", "F", "C", "Dm", "Gm", "Bb", "A",
        "Bb", "F", "Gm", "Dm", "Bb", "C", "A", "A7",
        "Dm", "Bb", "F", "C", "Dm", "Gm", "A", "Dm",
        "Gm", "Dm", "Bb", "F", "Gm", "Bb", "A", "A7"]
assert len(PROG) == BARS

A_MEL = [[("A4", 1.5), ("D5", .5), ("F5", 1), ("E5", 1)], [("D5", 2), ("F5", 1), ("D5", 1)],
         [("C5", 3), ("A4", 1)], [("E5", 2), ("D5", 1), ("C5", 1)],
         [("A4", 1.5), ("D5", .5), ("F5", 1), ("A5", 1)], [("G5", 2), ("Bb5", 1), ("G5", 1)],
         [("F5", 2), ("D5", 1), ("F5", 1)], [("E5", 3), ("C#5", 1)]]
B_MEL = [[("F5", 2), ("D5", 2)], [("C5", 2), ("A4", 1), ("C5", 1)], [("D5", 3), ("Bb4", 1)], [("A4", 4)],
         [("D5", 2), ("F5", 2)], [("G5", 2), ("E5", 1), ("C5", 1)], [("C#5", 2), ("E5", 2)], [("A5", 3), ("E5", 1)]]
A2_MEL = A_MEL[:6] + [[("E5", 2), ("C#5", 1), ("E5", 1)], [("D5", 4)]]
C_MEL = [[("Bb5", 2), ("A5", 1), ("G5", 1)], [("F5", 2), ("A5", 2)], [("F5", 1.5), ("D5", .5), ("F5", 1), ("Bb5", 1)],
         [("A5", 2), ("C6", 2)], [("Bb5", 2), ("G5", 2)], [("F5", 2), ("D5", 2)],
         [("E5", 2), ("C#5", 1), ("E5", 1)], [("A5", 2), ("G5", 1), ("E5", 1)]]
MELODY = A_MEL + B_MEL + A2_MEL + C_MEL

class Track:
    def __init__(self, ch, prog, name):
        self.ch, self.prog, self.name, self.ev = ch, prog, name, []
    def note(self, beat, dur, pitch, vel):
        vel = max(1, min(127, int(vel + rng.randint(-4, 4))))
        t0 = int(beat * TPB); t1 = int((beat + dur) * TPB) - 2
        self.ev.append((t0, 1, mido.Message("note_on", channel=self.ch, note=pitch, velocity=vel)))
        self.ev.append((t1, 0, mido.Message("note_off", channel=self.ch, note=pitch, velocity=0)))
    def cc(self, beat, num, val):
        self.ev.append((int(beat * TPB), 0, mido.Message("control_change", channel=self.ch, control=num, value=val)))

def save(tracks, path, passes=2, length_beats=BARS * 4):
    mid = mido.MidiFile(ticks_per_beat=TPB)
    meta = mido.MidiTrack(); mid.tracks.append(meta)
    meta.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(BPM)))
    for tr in tracks:
        t = mido.MidiTrack(); mid.tracks.append(t)
        ev = []
        if tr.ch != 9:
            ev.append((0, -1, mido.Message("program_change", channel=tr.ch, program=tr.prog)))
        ev.append((0, -1, mido.Message("control_change", channel=tr.ch, control=91, value=70)))  # reverb
        for p in range(passes):
            off = int(p * length_beats * TPB)
            ev += [(a + off, b, m) for a, b, m in tr.ev]
        ev.sort(key=lambda e: (e[0], e[1]))
        last = 0
        for a, _, m in ev:
            t.append(m.copy(time=a - last)); last = a
        # tail so reverb rings out
        t.append(mido.MetaMessage("end_of_track", time=TPB * 8))
    mid.save(path)

def chord_pcs(bar): return CH[PROG[bar]][1]
def root(bar): return N[CH[PROG[bar]][0]]
def voice(pcs, lo, hi):
    return sorted(p for p in range(lo, hi + 1) if p % 12 in pcs)

# ------------------------------------------------------------------ AMBIENT
def ambient():
    strings = Track(0, 49, "slow strings"); choir = Track(1, 52, "choir")
    harp = Track(2, 46, "harp"); cel = Track(3, 8, "celesta"); horn = Track(4, 60, "horn")
    bass = Track(5, 43, "contrabass")
    for b in range(BARS):
        s = b * 4; pcs = chord_pcs(b)
        for p in voice(pcs, n("D3"), n("A4"))[:4]:
            strings.note(s, 4, p, 46)
        bass.note(s, 4, 36 + (root(b) - 36) % 12 if root(b) % 12 >= 2 else 48 + root(b) % 12, 40)
        if b % 2 == 0:
            for p in voice(pcs, n("A4"), n("F5"))[:2]:
                choir.note(s, 8 if b + 1 < BARS else 4, p, 34)
        arp = voice(pcs, n("D4"), n("D6"))
        for i in range(8):
            if i % 2 == 0 or b % 4 == 3:
                harp.note(s + i * .5, 1.5, arp[(i * 2 + b) % len(arp)], 38 if i else 46)
        # celesta: fragments of the theme, every other bar, high and soft
        if b % 2 == 1:
            beat = s
            for nm, d in MELODY[b]:
                cel.note(beat, d, n(nm) + 12, 36)
                beat += d
        # horn sings the B-section melody gently
        if 8 <= b < 16:
            beat = s
            for nm, d in MELODY[b]:
                horn.note(beat, d, n(nm) - 12, 44)
                beat += d
    return [strings, choir, harp, cel, horn, bass]

# ------------------------------------------------------------------ TENSION
def tension():
    cello = Track(0, 42, "cello"); cb = Track(1, 43, "contrabass"); trem = Track(2, 44, "tremolo")
    timp = Track(3, 47, "timpani"); pizz = Track(4, 45, "pizzicato")
    pat = [0, 0, 12, 0, 7, 0, 12, 7]  # 8ths
    for b in range(BARS):
        s = b * 4; r = root(b); pcs = chord_pcs(b)
        low = 38 + (r - 38) % 12  # D2..C#3
        for i, iv in enumerate(pat):
            cello.note(s + i * .5, .45, low + 12 + (iv if iv != 12 else 12), 74 if i in (0, 3, 6) else 60)
        cb.note(s, 2, low, 70); cb.note(s + 2, 2, low, 62)
        for p in voice(pcs, n("A4"), n("E5"))[:2]:
            trem.note(s, 4, p, 50 + (b % 8) * 3)
        timp.note(s, 1, low + (12 if low < 41 else 0), 62)
        if b % 8 == 7:
            for i in range(8):
                timp.note(s + 2 + i * .25, .25, low + (12 if low < 41 else 0), 40 + i * 6)
        if b % 2 == 1:
            arp = voice(pcs, n("D4"), n("A5"))
            for i in (1, 3, 5, 7):
                pizz.note(s + i * .5, .5, arp[(i + b) % len(arp)], 52)
    return [cello, cb, trem, timp, pizz]

# ------------------------------------------------------------------ COMBAT
def combat():
    tpt = Track(0, 56, "trumpets"); horns = Track(1, 60, "horns"); bones = Track(2, 57, "trombones")
    tuba = Track(3, 58, "tuba"); brass = Track(4, 61, "brass section"); strs = Track(5, 48, "strings")
    timp = Track(6, 47, "timpani"); drums = Track(9, 0, "percussion")
    for b in range(BARS):
        s = b * 4; r = root(b); pcs = chord_pcs(b)
        sec = b // 8
        beat = s
        for nm, d in MELODY[b]:
            p = n(nm)
            if sec != 1: tpt.note(beat, d * .95, p, 100)
            horns.note(beat, d * .95, p - 12, 92 if sec == 1 else 84)
            beat += d
        # brass stabs: long on 1, accents on the "and" of 2 and on 4
        chordv = voice(pcs, n("F3"), n("D4"))[:3]
        for off, d, v in ((0, 1.4, 92), (1.5, .45, 84), (3, .9, 88)):
            for p in chordv: brass.note(s + off, d, p, v)
        for p in voice(pcs, n("A2"), n("A3"))[:2]:
            bones.note(s, 2, p, 86); bones.note(s + 2, 1.5, p, 80)
        low = 26 + (r - 26) % 12
        tuba.note(s, 2, low + 12, 84); tuba.note(s + 2, 2, low + 12 if b % 2 else low + 19, 78)
        # driving string ostinato in 16ths
        arp = voice(pcs, n("D4"), n("D6"))
        for i in range(16):
            strs.note(s + i * .25, .2, arp[[0, 1, 2, 1, 3, 2, 1, 2][i % 8] % len(arp)], 74 if i % 4 == 0 else 58)
        tl = 38 + (r - 38) % 12
        for off in (0, 1.5, 2, 3, 3.5):
            timp.note(s + off, .5, tl if off != 2 else tl + 7 - (12 if tl + 7 > 50 else 0), 96 if off == 0 else 76)
        # percussion: bass drum, snare, crash at section starts, roll into the next section
        for off in (0, 1.5, 2.5, 3):
            drums.note(s + off, .25, 35, 100 if off == 0 else 82)
        for off in (1, 3):
            drums.note(s + off, .25, 38, 70)
        if b % 8 == 0:
            drums.note(s, 2, 49, 96)
        if b % 8 == 7:
            for i in range(8):
                drums.note(s + 2 + i * .25, .25, 38, 50 + i * 7)
        if b % 2 == 1:
            drums.note(s + 3.5, .25, 49, 64)
    return [tpt, horns, bones, tuba, brass, strs, timp, drums]

# ------------------------------------------------------------------ STINGERS
def victory():
    tpt = Track(0, 56, "tpt"); horns = Track(1, 60, "hn"); brass = Track(2, 61, "br")
    strs = Track(3, 48, "str"); timp = Track(4, 47, "timp"); dr = Track(9, 0, "dr"); tuba = Track(5, 58, "tuba")
    seq = [("A4", .5), ("D5", .5), ("F#5", .5), ("A5", 1.5), ("G5", .5), ("F#5", .5), ("E5", .5), ("F#5", 3)]
    beat = 0
    for nm, d in seq:
        tpt.note(beat, d, n(nm), 108); horns.note(beat, d, n(nm) - 12, 96); beat += d
    for c, at, d in ((["D", "F#", "A"], 0, 1.5), (["G", "B", "D"], 3, 1.5), (["D", "F#", "A"], 4.5, 3.5)):
        pcs = [N[x] for x in c]
        for p in voice(pcs, n("F3"), n("D5")): brass.note(at, d, p, 92); strs.note(at, d, p + 12, 84)
        tuba.note(at, d, 38 + (N[c[0]] - 2) % 12, 90)
    for i in range(12): timp.note(3 + i * .125, .125, 38, 60 + i * 4)
    timp.note(4.5, 2, 38, 110); dr.note(4.5, 3, 49, 110); dr.note(4.5, .5, 35, 110)
    return [tpt, horns, brass, strs, timp, dr, tuba], 8

def defeat():
    horn = Track(0, 60, "hn"); strs = Track(1, 48, "str"); cb = Track(2, 43, "cb"); timp = Track(3, 47, "timp")
    seq = [("A4", 1), ("F4", 1), ("E4", 1), ("D4", 4)]
    beat = 0
    for nm, d in seq: horn.note(beat, d, n(nm), 80); beat += d
    for c, at, d in ((["D", "F", "A"], 0, 2), (["Bb", "D", "F"], 2, 1), (["A", "C#", "E"], 3, 1), (["D", "F", "A"], 4, 4)):
        pcs = [N[x] for x in c]
        for p in voice(pcs, n("D3"), n("A4")): strs.note(at, d, p, 66)
        cb.note(at, d, 26 + (N[c[0]] - 2) % 12 + 12, 70)
    timp.note(0, 2, 38, 90); timp.note(4, 3, 38, 70)
    return [horn, strs, cb, timp], 8

# ------------------------------------------------------------------ RENDER
def render(mid, wav, gain):
    subprocess.run(["fluidsynth", "-ni", "-g", str(gain), "-r", str(SR), "-F", wav, SF2, mid],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    sr, x = wavfile.read(wav)
    return x.astype(np.float32) / 32768.0

def encode(x, path, q):
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f: tmp = f.name
    wavfile.write(tmp, SR, (np.clip(x, -1, 1) * 32767).astype(np.int16))
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", tmp, "-c:a", "libvorbis", "-q:a", str(q), path], check=True)
    os.unlink(tmp)

def main():
    os.makedirs(OUT, exist_ok=True)
    loop = int(round(BARS * 4 * 60 / BPM * SR))
    td = tempfile.mkdtemp()
    stems = {"ambient": (ambient(), 0.5, 0.55), "tension": (tension(), 0.5, 0.6), "combat": (combat(), 0.45, 0.75)}
    for name, (tracks, gain, peak) in stems.items():
        mid = os.path.join(td, name + ".mid"); wav = os.path.join(td, name + ".wav")
        save(tracks, mid, passes=3)
        x = render(mid, wav, gain)
        # take the middle pass: it already carries the reverb tail of the pass before it,
        # so the loop point is seamless
        seg = x[loop:2 * loop]
        seg = seg / max(1e-6, np.max(np.abs(seg))) * peak
        encode(seg, os.path.join(OUT, name + ".ogg"), 2)
        print(name, "%.1fs" % (len(seg) / SR))
    for name, fn, peak in (("victory", victory, 0.8), ("defeat", defeat, 0.6)):
        tracks, beats = fn()
        mid = os.path.join(td, name + ".mid"); wav = os.path.join(td, name + ".wav")
        save(tracks, mid, passes=1, length_beats=beats)
        x = render(mid, wav, 0.5)
        nz = np.where(np.abs(x).max(axis=1) > 1e-4)[0]
        x = x[: nz[-1] + 1] if len(nz) else x
        x = x / max(1e-6, np.max(np.abs(x))) * peak
        encode(x, os.path.join(OUT, name + ".ogg"), 3)
        print(name, "%.1fs" % (len(x) / SR))

if __name__ == "__main__":
    main()
