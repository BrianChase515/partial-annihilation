#!/usr/bin/env python3
"""Three War is Hell suites (Commander of Heroes): grim, military and dissonant - field drums,
low brass clusters, tolling bells, and no comfort. Each has ambient / tension / combat stems that
loop together (32 bars), like the rest of the score.

  Suite M "No Man's Land":  D phrygian, 72 bpm  - a low drone, distant snare rolls, a tolling bell;
                            the fight brings pounding toms and tritone brass stabs.
  Suite N "Iron Rain":      E phrygian, 124 bpm - industrial: taiko and kick, distorted power chords,
                            shrieking strings and brass hits.
  Suite O "The Long Night": C minor, 60 bpm     - a funeral march: military snare cadence, muted
                            trumpet, a choir that never resolves.

Uses the helpers in compose.py. Run: python3 tools/compose_wih.py [m n o]"""
import os, sys, random, tempfile
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compose as C

BARS = 32
SR = C.SR
KICK, SNARE, SNARE2, TOM_LO, TOM_MID, TOM_HI, CRASH, CHINA, RIDE = 36, 38, 40, 41, 45, 48, 49, 52, 51


def roll(dr, start, beats, vel0, vel1, step=0.125, note=SNARE):
    """a snare roll that swells from vel0 to vel1"""
    n = int(beats / step)
    for i in range(n):
        dr.note(start + i * step, step * 0.8, note, vel0 + (vel1 - vel0) * i / max(1, n - 1))


def cadence(dr, s, v=1.0):
    """one bar of a military snare cadence (flams and a roll)"""
    for off, vel in ((0, 96), (0.75, 60), (1, 84), (1.5, 70), (2, 96), (2.25, 58), (2.5, 70)):
        dr.note(s + off, .1, SNARE, vel * v)
    roll(dr, s + 3, 1, 50 * v, 92 * v, 0.125)


# ---------------------------------------------------------------------------- Suite M
def suite_m():
    """No Man's Land: D phrygian, 72 bpm."""
    rng = random.Random(1916)
    roots = [38, 38, 39, 38, 36, 38, 39, 41, 38, 38, 44, 43, 39, 38, 36, 37] * 2  # D, Eb (b2), C, F, Ab (tritone)

    def ambient():
        drone = C.Track(0, 43, "contrabass"); low = C.Track(1, 58, "tuba"); bell = C.Track(2, 14, "bell")
        dr = C.Track(9, 0, "drums"); pad = C.Track(3, 49, "slow strings")
        for b in range(BARS):
            s = b * 4; r = roots[b]
            drone.note(s, 4, r, 46); drone.note(s, 4, r + 1, 22)       # a minor-second rub that never goes away
            if b % 4 == 0: low.note(s, 8, r - 12, 40)
            if b % 4 == 2: bell.note(s + 1, 3, 62, 38)                  # a far-off toll
            if b % 8 in (3, 7): roll(dr, s + 2, 2, 18, 46)              # distant snare, coming and going
            for p in (r + 12, r + 13, r + 19): pad.note(s, 4, p, 26 + (b % 8) * 2)
        return [drone, low, bell, dr, pad]

    def tension():
        strs = C.Track(0, 48, "strings"); bones = C.Track(1, 57, "bones"); bell = C.Track(2, 14, "bell")
        dr = C.Track(9, 0, "drums"); tim = C.Track(3, 47, "timp")
        for b in range(BARS):
            s = b * 4; r = roots[b]
            for i in range(8): strs.note(s + i * .5, .3, r + 12 + (1 if i % 4 == 3 else 0), 70 if i % 2 == 0 else 52)
            cadence(dr, s, 0.8)
            tim.note(s, .5, r, 70); tim.note(s + 2, .5, r, 56)
            if b % 4 == 3: bones.note(s, 4, r + 6, 62)                   # the tritone, held
            if b % 8 == 0: bell.note(s, 4, 62, 50)
        return [strs, bones, bell, dr, tim]

    def combat():
        strs = C.Track(0, 48, "strings"); brass = C.Track(1, 61, "brass"); bones = C.Track(2, 57, "bones")
        tuba = C.Track(3, 58, "tuba"); dr = C.Track(9, 0, "drums"); bell = C.Track(4, 14, "bell")
        for b in range(BARS):
            s = b * 4; r = roots[b]
            for i in range(16): strs.note(s + i * .25, .2, r + 12 + [0, 1, 0, 6, 0, 1, 0, 3][i % 8], 84 if i % 4 == 0 else 60)
            for off in (0, 1.5, 3):
                for p in (r + 12, r + 18, r + 24): brass.note(s + off, .4, p, 104)   # tritone stabs
                bones.note(s + off, .4, r + 7, 96)
            tuba.note(s, 1.5, r - 12, 100); tuba.note(s + 2, 1.5, r - 11, 92)
            for off, n, v in ((0, KICK, 118), (0, TOM_LO, 110), (1, TOM_MID, 96), (1.5, TOM_LO, 104), (2, KICK, 116),
                              (2.5, TOM_HI, 90), (3, TOM_LO, 108), (3.5, TOM_MID, 98)):
                dr.note(s + off, .2, n, v)
            for off in (0.5, 1.25, 2.75): dr.note(s + off, .1, SNARE, 92)
            if b % 4 == 3: roll(dr, s + 2, 2, 60, 120)
            if b % 8 == 0: dr.note(s, .5, CHINA, 110); bell.note(s, 2, 62, 80)
        return [strs, brass, bones, tuba, dr, bell]

    return "m", 72, ambient, tension, combat


# ---------------------------------------------------------------------------- Suite N
def suite_n():
    """Iron Rain: E phrygian, 124 bpm - industrial."""
    rng = random.Random(1944)
    riff = [40, 40, 41, 40, 40, 43, 41, 40]     # E, F, G
    roots = [40, 40, 41, 40, 38, 40, 46, 45] * 4

    def ambient():
        gtr = C.Track(0, 29, "overdrive"); pad = C.Track(1, 95, "sweep pad"); dr = C.Track(9, 0, "drums")
        bass = C.Track(2, 38, "synth bass")
        for b in range(BARS):
            s = b * 4; r = roots[b]
            bass.note(s, 4, r - 12, 50)
            if b % 2 == 0: gtr.note(s, 4, r, 34); gtr.note(s, 4, r + 7, 30)
            for p in (r + 12, r + 13): pad.note(s, 4, p, 30)
            dr.note(s, .2, KICK, 54); dr.note(s + 2, .2, KICK, 46)
            if b % 4 == 3: dr.note(s + 3, .3, CHINA, 40)
        return [gtr, pad, dr, bass]

    def tension():
        gtr = C.Track(0, 30, "distortion"); strs = C.Track(1, 44, "tremolo"); dr = C.Track(9, 0, "drums")
        bass = C.Track(2, 38, "synth bass")
        for b in range(BARS):
            s = b * 4; r = roots[b]
            for i in range(8):
                n = riff[i] + (r - 40)
                gtr.note(s + i * .5, .4, n, 82); gtr.note(s + i * .5, .4, n + 7, 70)
                bass.note(s + i * .5, .4, n - 12, 76)
            for p in (r + 24, r + 25): strs.note(s, 4, p, 48)
            for off in (0, 1, 2, 3): dr.note(s + off, .2, KICK, 96)
            for off in (1, 3): dr.note(s + off, .2, SNARE2, 90)
        return [gtr, strs, dr, bass]

    def combat():
        gtr = C.Track(0, 30, "distortion"); brass = C.Track(1, 61, "brass"); strs = C.Track(2, 48, "strings")
        taiko = C.Track(3, 116, "taiko"); dr = C.Track(9, 0, "drums"); bass = C.Track(4, 38, "synth bass")
        for b in range(BARS):
            s = b * 4; r = roots[b]
            for i in range(16):
                n = riff[(i // 2) % 8] + (r - 40)
                gtr.note(s + i * .25, .22, n, 100 if i % 2 == 0 else 84); gtr.note(s + i * .25, .22, n + 7, 88)
                bass.note(s + i * .25, .22, n - 12, 96)
            for off in (0, 0.75, 2, 3.5):
                for p in (r + 12, r + 13, r + 19): brass.note(s + off, .3, p, 112)
            for i in range(8): strs.note(s + i * .5, .45, r + 24 + (1 if i % 2 else 0), 80)
            for off, v in ((0, 124), (0.5, 90), (1, 118), (1.75, 96), (2, 124), (2.5, 90), (3, 118), (3.5, 104)): taiko.note(s + off, .25, 48, v)
            for i in range(8): dr.note(s + i * .5, .15, KICK, 110)
            for off in (1, 3): dr.note(s + off, .2, SNARE, 118)
            if b % 4 == 3: roll(dr, s + 2, 2, 70, 124, 0.0625)
            if b % 4 == 0: dr.note(s, .5, CRASH, 112)
        return [gtr, brass, strs, taiko, dr, bass]

    return "n", 124, ambient, tension, combat


# ---------------------------------------------------------------------------- Suite O
def suite_o():
    """The Long Night: C minor, 60 bpm - a funeral march."""
    rng = random.Random(1918)
    prog_roots = [36, 36, 32, 31, 36, 29, 32, 31, 36, 37, 32, 31, 29, 30, 31, 31] * 2   # C, Ab, G, F, Db, Gb
    call = [[(67, 1.5), (72, .5), (75, 2)], [(74, 1), (72, 1), (71, 2)], [(67, 3), (66, 1)], [(67, 4)]]

    def ambient():
        choir = C.Track(0, 52, "choir aahs"); bass = C.Track(1, 43, "contrabass"); dr = C.Track(9, 0, "drums")
        tpt = C.Track(2, 59, "muted trumpet"); bell = C.Track(3, 14, "bell")
        for b in range(BARS):
            s = b * 4; r = prog_roots[b]
            bass.note(s, 4, r, 44)
            for p in (r + 24, r + 27, r + 30): choir.note(s, 4, p, 30)       # a diminished chord that never resolves
            dr.note(s, .1, SNARE, 40); dr.note(s + 2, .1, SNARE, 30)          # the slow march, far away
            if b % 8 in (4, 5, 6, 7):
                beat = s
                for p, d in call[b % 4]: tpt.note(beat, d * .9, p, 44); beat += d
            if b % 4 == 0: bell.note(s, 4, 60, 34)
        return [choir, bass, dr, tpt, bell]

    def tension():
        choir = C.Track(0, 52, "choir"); strs = C.Track(1, 48, "strings"); dr = C.Track(9, 0, "drums")
        tpt = C.Track(2, 56, "trumpet"); tim = C.Track(3, 47, "timp")
        for b in range(BARS):
            s = b * 4; r = prog_roots[b]
            for p in (r + 24, r + 27, r + 31): choir.note(s, 4, p, 44)
            for i in range(4): strs.note(s + i, .9, r + 12, 64)
            cadence(dr, s, 0.9)
            tim.note(s, 1, r, 74); tim.note(s + 3, 1, r, 60)
            if b % 8 >= 4:
                beat = s
                for p, d in call[b % 4]: tpt.note(beat, d * .9, p, 70); beat += d
        return [choir, strs, dr, tpt, tim]

    def combat():
        choir = C.Track(0, 52, "choir"); brass = C.Track(1, 61, "brass"); strs = C.Track(2, 48, "strings")
        tpt = C.Track(3, 56, "trumpet"); dr = C.Track(9, 0, "drums"); tuba = C.Track(4, 58, "tuba")
        for b in range(BARS):
            s = b * 4; r = prog_roots[b]
            for p in (r + 24, r + 27, r + 30, r + 31): choir.note(s, 2, p, 90); choir.note(s + 2, 2, p, 84)
            for i in range(8): strs.note(s + i * .5, .4, r + 12 + (6 if i % 4 == 3 else 0), 86 if i % 2 == 0 else 66)
            beat = s
            for p, d in call[b % 4]: tpt.note(beat, d * .9, p + (12 if b >= 24 else 0), 104); beat += d
            for off in (0, 2): brass.note(s + off, 1.5, r + 12, 100); brass.note(s + off, 1.5, r + 18, 96)
            tuba.note(s, 2, r - 12, 104); tuba.note(s + 2, 2, r - 6, 96)
            cadence(dr, s, 1.25)
            dr.note(s, .3, KICK, 120); dr.note(s + 2, .3, KICK, 116); dr.note(s + 1, .3, TOM_LO, 104); dr.note(s + 3, .3, TOM_LO, 100)
            if b % 8 == 0: dr.note(s, .5, CRASH, 116)
        return [choir, brass, strs, tpt, dr, tuba]

    return "o", 60, ambient, tension, combat


def main():
    os.makedirs(C.OUT, exist_ok=True)
    td = tempfile.mkdtemp()
    makers = {"m": suite_m, "n": suite_n, "o": suite_o}
    want = sys.argv[1:] or list(makers)
    for make in (makers[k] for k in want):
        tag, bpm, amb, ten, com = make()
        C.BPM = bpm
        loop = int(round(BARS * 4 * 60 / bpm * SR))
        for name, fn, gain, peak in (("ambient", amb, 0.5, 0.55), ("tension", ten, 0.5, 0.62), ("combat", com, 0.45, 0.8)):
            tracks = fn()
            mid = os.path.join(td, f"{name}_{tag}.mid"); wav = os.path.join(td, f"{name}_{tag}.wav")
            C.save(tracks, mid, passes=3, length_beats=BARS * 4)
            x = C.render(mid, wav, gain)
            seg = x[loop:2 * loop]
            seg = seg / max(1e-6, np.max(np.abs(seg))) * peak
            C.encode(seg, os.path.join(C.OUT, f"{name}_{tag}.ogg"), 2)
            print(f"{name}_{tag}", "%.1fs" % (len(seg) / SR))


if __name__ == "__main__":
    main()
