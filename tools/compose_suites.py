#!/usr/bin/env python3
"""Two more score suites for Partial Annihilation, each with ambient / tension / combat
stems that loop in sync (32 bars), so the game can pick a different soundtrack per match.

  Suite B "Iron Tide": E minor, 100 bpm - driving strings, war drums, brass fanfares.
  Suite C "Ashfall":   C minor, 76 bpm - dark choir, low brass, heavy percussion.

Uses the helpers in compose.py. Run: python3 tools/compose_suites.py"""
import os, sys, random, tempfile
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compose as C

BARS = 32
SR = C.SR

PC = {"C": 0, "C#": 1, "Db": 1, "D": 2, "Eb": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "Ab": 8, "A": 9, "Bb": 10, "B": 11}

def chord(name):
    minor = name.endswith("m")
    root = name[:-1] if minor else name
    r = PC[root]
    return r, [r % 12, (r + (3 if minor else 4)) % 12, (r + 7) % 12]

def scale_of(tonic, minor=True):
    steps = [0, 2, 3, 5, 7, 8, 10] if minor else [0, 2, 4, 5, 7, 9, 11]
    return [(tonic + s) % 12 for s in steps]

CELLS = {
    "heroic": [[1.5, .5, 1, 1], [2, 1, 1], [1, 1, 2], [3, 1], [.5, .5, 1, 2], [1, .5, .5, 2]],
    "dark":   [[2, 2], [3, 1], [1, 1, 2], [4], [1.5, .5, 2], [2, 1, 1]],
}

def gen_melody(prog, tonic, rng, lo, hi, style):
    """32 bars of melody: phrase A (8), B (8), A' (8), climax C (8)."""
    sc = scale_of(tonic)
    cells = CELLS[style]
    pitches = [p for p in range(lo, hi + 1) if p % 12 in sc]

    def phrase(bars, start_pitch, lift=0):
        out, cur = [], start_pitch
        for b in bars:
            _, ct = chord(prog[b])
            cell = cells[rng.randrange(len(cells))]
            notes = []
            for i, d in enumerate(cell):
                if i == 0:
                    # strong beat: nearest chord tone (with a little upward pull in the climax)
                    cands = [p for p in pitches if p % 12 in ct]
                    cur = min(cands, key=lambda p: abs(p - (cur + lift)) + rng.random() * 2)
                else:
                    step = rng.choice([-2, -1, 1, 1, 2, 3, -3])
                    idx = min(range(len(pitches)), key=lambda k: abs(pitches[k] - cur))
                    cur = pitches[max(0, min(len(pitches) - 1, idx + step))]
                notes.append((cur, d))
            out.append(notes)
        return out

    A = phrase(range(0, 8), (lo + hi) // 2)
    B = phrase(range(8, 16), (lo + hi) // 2 + 3)
    A2 = [list(bar) for bar in A[:6]] + phrase(range(22, 24), A[5][-1][0])
    # make bar 24 land on the tonic
    tonic_p = min([p for p in pitches if p % 12 == tonic], key=lambda p: abs(p - (lo + hi) // 2))
    A2[7] = [(tonic_p, 4)]
    Cl = phrase(range(24, 32), (lo + hi) // 2 + 5, lift=2)
    return A + B + A2 + Cl

def vce(pcs, lo, hi):
    return sorted(p for p in range(lo, hi + 1) if p % 12 in pcs)

# ---------------------------------------------------------------------------- Suite B
def suite_b():
    rng = random.Random(21)
    prog = ["Em", "C", "G", "D", "Em", "C", "Am", "B", "C", "D", "G", "Em", "Am", "C", "B", "B",
            "Em", "C", "G", "D", "Em", "Am", "B", "Em", "C", "G", "Am", "Em", "C", "D", "B", "B"]
    mel = gen_melody(prog, PC["E"], rng, 64, 81, "heroic")

    def ambient():
        pad = C.Track(0, 48, "strings"); flute = C.Track(1, 73, "flute"); harp = C.Track(2, 46, "harp")
        clar = C.Track(3, 71, "clarinet"); bass = C.Track(4, 43, "contrabass")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            for p in vce(pcs, 52, 69)[:4]: pad.note(s, 4, p, 40)
            bass.note(s, 4, 28 + (r - 28) % 12 + 12, 38)
            arp = vce(pcs, 55, 84)
            for i in range(16):
                if i % 2 == 0 or b % 8 == 7:
                    harp.note(s + i * .25, .6, arp[(i + b) % len(arp)], 30 if i % 4 else 38)
            if b % 4 in (1, 2):
                beat = s
                for p, d in mel[b]:
                    flute.note(beat, d, p + 12, 40); beat += d
            if 8 <= b < 16 or b >= 24:
                beat = s + 2
                ct = vce(pcs, 55, 67)
                clar.note(beat, 2, ct[(b) % len(ct)], 36)
        return [pad, flute, harp, clar, bass]

    def tension():
        pizz = C.Track(0, 45, "pizz"); bsn = C.Track(1, 70, "bassoon"); trem = C.Track(2, 44, "trem")
        timp = C.Track(3, 47, "timp"); low = C.Track(4, 42, "cello")
        pat = [0, 7, 12, 7, 0, 7, 12, 15]
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 40 + (r - 40) % 12
            for i, iv in enumerate(pat):
                p = base + iv
                if p % 12 not in pcs and iv == 15: p = base + 12
                pizz.note(s + i * .5, .4, p + 12, 66 if i % 4 == 0 else 52)
            low.note(s, 1.8, base, 64); low.note(s + 2, 1.8, base, 58)
            bsn.note(s + 3, 1, base + 7 if (base + 7) % 12 in pcs else base + 12, 50)
            for p in vce(pcs, 71, 79)[:2]: trem.note(s, 4, p, 40 + (b % 8) * 3)
            timp.note(s, .5, base if base >= 40 else base + 12, 70)
            timp.note(s + 2.5, .5, base if base >= 40 else base + 12, 52)
            if b % 8 == 7:
                for i in range(8): timp.note(s + 2 + i * .25, .25, base, 46 + i * 6)
        return [pizz, bsn, trem, timp, low]

    def combat():
        strs = C.Track(0, 48, "strings"); brass = C.Track(1, 61, "brass"); tpt = C.Track(2, 56, "tpt")
        bones = C.Track(3, 57, "bones"); timp = C.Track(4, 47, "timp"); horns = C.Track(5, 60, "horns")
        dr = C.Track(9, 0, "drums")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 40 + (r - 40) % 12
            for i in range(16):
                p = base + (12 if i % 4 in (1, 3) else (19 if i % 8 == 6 else 0)) + 12
                strs.note(s + i * .25, .2, p, 76 if i % 4 == 0 else 58)
            beat = s
            for p, d in mel[b]:
                horns.note(beat, d * .95, p, 92); brass.note(beat, d * .95, p - 12, 80); beat += d
            if b % 2 == 1:
                ct = vce(pcs, 67, 79)
                for k, off in enumerate((3, 3.33, 3.66)): tpt.note(s + off, .3, ct[k % len(ct)], 100)
            for p in vce(pcs, 45, 57)[:2]:
                bones.note(s + 0.5, .5, p, 84); bones.note(s + 2.5, 1, p, 88)
            for off in (0, .75, 1.5, 2, 3, 3.5):
                timp.note(s + off, .4, base if base >= 40 else base + 12, 98 if off in (0, 2) else 74)
            # war drums: toms and a big hit on 1
            for off, nn, v in ((0, 41, 110), (.5, 43, 80), (1, 45, 90), (1.5, 43, 80), (2, 41, 105), (2.75, 45, 85), (3, 43, 95), (3.5, 41, 90)):
                dr.note(s + off, .25, nn, v)
            dr.note(s, .25, 36, 110)
            if b % 8 == 0: dr.note(s, 2, 57, 100)
            if b % 4 == 3: dr.note(s + 3.5, .25, 49, 80)
        return [strs, brass, tpt, bones, timp, horns, dr]

    return "b", 100, ambient, tension, combat

# ---------------------------------------------------------------------------- Suite C
def suite_c():
    rng = random.Random(77)
    prog = ["Cm", "Ab", "Eb", "Bb", "Cm", "Fm", "G", "G", "Ab", "Bb", "Cm", "Cm", "Fm", "Ab", "G", "G",
            "Cm", "Ab", "Eb", "Bb", "Fm", "Cm", "G", "Cm", "Ab", "Fm", "Cm", "Bb", "Ab", "Bb", "G", "G"]
    mel = gen_melody(prog, PC["C"], rng, 60, 77, "dark")

    def ambient():
        choir = C.Track(0, 52, "choir"); cello = C.Track(1, 42, "cello"); cel = C.Track(2, 8, "celesta")
        pad = C.Track(3, 49, "slow strings"); bass = C.Track(4, 43, "bass")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            for p in vce(pcs, 55, 72)[:3]: choir.note(s, 4, p, 36)
            for p in vce(pcs, 48, 60)[:2]: pad.note(s, 4, p, 32)
            bass.note(s, 4, 24 + (r - 24) % 12 + 12, 40)
            if b % 2 == 0:
                beat = s
                for p, d in mel[b]:
                    cello.note(beat, d, p - 12, 46); beat += d
            if b % 4 == 3:
                ct = vce(pcs, 79, 91)
                for i in range(4): cel.note(s + i, 1, ct[i % len(ct)], 30)
        return [choir, cello, cel, pad, bass]

    def tension():
        low = C.Track(0, 48, "low strings"); bass = C.Track(1, 43, "bass"); timp = C.Track(2, 47, "timp")
        horn = C.Track(3, 60, "horn"); trem = C.Track(4, 44, "trem")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 36 + (r - 36) % 12
            # dotted heartbeat ostinato
            for off in (0, .75, 1, 2, 2.75, 3):
                low.note(s + off, .3, base + 12, 72 if off in (0, 2) else 56)
            bass.note(s, 4, base, 60)
            timp.note(s, .6, base + 12 if base + 12 <= 50 else base, 66)
            if b % 4 == 3:
                for i in range(12): timp.note(s + 1 + i * (1 / 4), .25, base + 12 if base + 12 <= 50 else base, 40 + i * 5)
            if b % 8 in (2, 6):
                ct = vce(pcs, 55, 67)
                horn.note(s, 1.5, ct[0], 58); horn.note(s + 1.5, 2.5, ct[-1], 62)
            for p in vce(pcs, 67, 75)[:2]: trem.note(s, 4, p, 36 + (b % 8) * 3)
        return [low, bass, timp, horn, trem]

    def combat():
        choir = C.Track(0, 52, "choir"); brass = C.Track(1, 61, "brass"); tuba = C.Track(2, 58, "tuba")
        strs = C.Track(3, 48, "strings"); timp = C.Track(4, 47, "timp"); horns = C.Track(5, 60, "horns")
        dr = C.Track(9, 0, "drums")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 36 + (r - 36) % 12
            for p in vce(pcs, 55, 74)[:4]: choir.note(s, 4, p, 84)
            beat = s
            for p, d in mel[b]:
                horns.note(beat, d * .95, p, 96); brass.note(beat, d * .95, p - 12, 86); beat += d
            tuba.note(s, 1.5, base, 92); tuba.note(s + 1.5, .5, base, 80); tuba.note(s + 2, 2, base + 7 if base + 7 <= 50 else base - 5, 86)
            arp = vce(pcs, 48, 72)
            for i in range(16):
                strs.note(s + i * .25, .2, arp[[0, 2, 1, 3, 2, 4, 3, 1][i % 8] % len(arp)], 74 if i % 4 == 0 else 56)
            for off in (0, .5, 1, 2, 2.5, 3, 3.25, 3.5):
                timp.note(s + off, .3, base + 12 if base + 12 <= 50 else base, 100 if off in (0, 2) else 76)
            for off in (0, 1.5, 2, 3.5): dr.note(s + off, .25, 35, 112 if off == 0 else 90)
            for off in (1, 3): dr.note(s + off, .25, 40, 84)
            if b % 4 == 0: dr.note(s, 2, 52, 96)
            if b % 8 == 7:
                for i in range(8): dr.note(s + 2 + i * .25, .25, 38, 56 + i * 7)
        return [choir, brass, tuba, strs, timp, horns, dr]

    return "c", 76, ambient, tension, combat

# ---------------------------------------------------------------------------- Suite D
def suite_d():
    """Overdrive: A minor, 112 bpm - marimba and oboe calm, racing staccato strings, taiko and brass stabs."""
    rng = random.Random(305)
    prog = ["Am", "F", "C", "G", "Am", "F", "Dm", "E", "F", "G", "Am", "Am", "Dm", "F", "E", "E",
            "Am", "F", "C", "G", "F", "Dm", "E", "Am", "F", "G", "C", "Am", "Dm", "F", "E", "E"]
    mel = gen_melody(prog, PC["A"], rng, 64, 81, "heroic")

    def ambient():
        mar = C.Track(0, 12, "marimba"); oboe = C.Track(1, 68, "oboe"); pad = C.Track(2, 49, "slow strings")
        vib = C.Track(3, 11, "vibes"); bass = C.Track(4, 32, "ac bass")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            for p in vce(pcs, 52, 67)[:3]: pad.note(s, 4, p, 34)
            bass.note(s, 2, 33 + (r - 33) % 12, 44); bass.note(s + 2.5, 1.5, 33 + (r - 33) % 12 + 7 if (r + 7) % 12 in pcs else 33 + (r - 33) % 12, 36)
            arp = vce(pcs, 60, 79)
            for i in range(8):
                mar.note(s + i * .5, .5, arp[[0, 2, 1, 3, 2, 1, 3, 4][i] % len(arp)], 40 if i % 2 == 0 else 30)
            if b % 4 in (0, 1) and b >= 4:
                beat = s
                for p, d in mel[b]:
                    oboe.note(beat, d, p, 44); beat += d
            if b % 8 == 7:
                for i, p in enumerate(vce(pcs, 72, 88)[:4]): vib.note(s + i * .5, 2, p, 34)
        return [mar, oboe, pad, vib, bass]

    def tension():
        sto = C.Track(0, 45, "pizz"); vla = C.Track(1, 48, "strings"); taiko = C.Track(2, 116, "taiko")
        low = C.Track(3, 42, "cello"); trem = C.Track(4, 44, "trem")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 45 + (r - 45) % 12
            for i in range(16):
                p = base + [0, 12, 7, 12, 0, 12, 7, 15][i % 8]
                if p % 12 not in pcs: p = base + 12
                vla.note(s + i * .25, .18, p, 60 if i % 4 == 0 else 44)
            low.note(s, 4, base - 12, 58)
            for off in (0, 1.5, 3): taiko.note(s + off, .5, 48 if off == 0 else 45, 72 if off == 0 else 58)
            for p in vce(pcs, 72, 81)[:2]: trem.note(s, 4, p, 34 + (b % 8) * 3)
            if b % 2 == 1: sto.note(s + 3.5, .3, base + 24, 60)
        return [sto, vla, taiko, low, trem]

    def combat():
        strs = C.Track(0, 48, "strings"); brass = C.Track(1, 61, "brass"); tpt = C.Track(2, 56, "tpt")
        bones = C.Track(3, 57, "bones"); taiko = C.Track(4, 116, "taiko"); horns = C.Track(5, 60, "horns")
        dr = C.Track(9, 0, "drums")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 45 + (r - 45) % 12
            for i in range(16):
                strs.note(s + i * .25, .18, base + 12 + [0, 7, 12, 7][i % 4], 80 if i % 4 == 0 else 60)
            beat = s
            for p, d in mel[b]:
                horns.note(beat, d * .95, p, 94); tpt.note(beat, d * .9, p + 12 if b >= 24 else p, 70 if b < 24 else 92); beat += d
            # syncopated tutti stabs
            for off in (0, 1.5, 3):
                for p in vce(pcs, 48, 62)[:3]: brass.note(s + off, .4, p, 96 if off == 0 else 84)
                bones.note(s + off, .4, base - 12 if base - 12 >= 40 else base, 92)
            for off, v in ((0, 115), (.75, 85), (1.5, 100), (2, 90), (2.5, 80), (3, 105), (3.5, 85)):
                taiko.note(s + off, .3, 48, v)
            dr.note(s, .25, 36, 110); dr.note(s + 2, .25, 36, 100)
            for off in (1, 3): dr.note(s + off, .25, 38, 96)
            if b % 8 == 7:
                for i in range(8): dr.note(s + 2 + i * .25, .25, 38, 60 + i * 7)
            if b % 8 == 0: dr.note(s, 2, 49, 104)
        return [strs, brass, tpt, bones, taiko, horns, dr]

    return "d", 112, ambient, tension, combat

# ---------------------------------------------------------------------------- Suite E
def suite_e():
    """Last Light: G minor, 88 bpm - piano and solo horn calm, triplet string ostinato, a snare-driven march."""
    rng = random.Random(4242)
    prog = ["Gm", "Eb", "Bb", "F", "Gm", "Cm", "D", "D", "Eb", "F", "Bb", "Gm", "Cm", "Eb", "D", "D",
            "Gm", "Eb", "Bb", "F", "Cm", "Gm", "D", "Gm", "Eb", "Cm", "Gm", "F", "Eb", "F", "D", "D"]
    mel = gen_melody(prog, PC["G"], rng, 62, 79, "dark")

    def ambient():
        pno = C.Track(0, 0, "piano"); horn = C.Track(1, 60, "horn"); pad = C.Track(2, 48, "strings")
        harp = C.Track(3, 46, "harp"); bass = C.Track(4, 43, "contrabass")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            for p in vce(pcs, 50, 65)[:3]: pad.note(s, 4, p, 32)
            bass.note(s, 4, 31 + (r - 31) % 12, 36)
            ct = vce(pcs, 55, 74)
            for i in range(4): pno.note(s + i, 1.2, ct[(i * 2 + b) % len(ct)], 38 if i == 0 else 30)
            if b % 8 in (2, 3, 4, 5):
                beat = s
                for p, d in mel[b]:
                    horn.note(beat, d, p - 12, 44); beat += d
            if b % 4 == 3:
                for i, p in enumerate(vce(pcs, 67, 86)[:6]): harp.note(s + 2 + i * .33, 1, p, 32)
        return [pno, horn, pad, harp, bass]

    def tension():
        strs = C.Track(0, 48, "strings"); low = C.Track(1, 42, "cello"); timp = C.Track(2, 47, "timp")
        brass = C.Track(3, 61, "brass"); sn = C.Track(9, 0, "drums")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 43 + (r - 43) % 12
            for i in range(12):   # triplet ostinato
                strs.note(s + i / 3, .3, base + [12, 15, 19][i % 3] if (base + 15) % 12 in pcs else base + [12, 16, 19][i % 3], 58 if i % 3 == 0 else 44)
            low.note(s, 4, base - 12 if base - 12 >= 36 else base, 60)
            timp.note(s, .6, base if base <= 50 else base - 12, 64)
            if b % 4 == 3:   # low brass swell
                for p in vce(pcs, 43, 55)[:2]:
                    for k in range(4): brass.note(s + k, 1, p, 40 + k * 10)
            for off in (0, 2): sn.note(s + off + 1, .2, 38, 34)
        return [strs, low, timp, brass, sn]

    def combat():
        choir = C.Track(0, 52, "choir"); brass = C.Track(1, 61, "brass"); horns = C.Track(2, 60, "horns")
        strs = C.Track(3, 48, "strings"); timp = C.Track(4, 47, "timp"); tuba = C.Track(5, 58, "tuba")
        dr = C.Track(9, 0, "drums")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 43 + (r - 43) % 12
            for p in vce(pcs, 55, 72)[:3]: choir.note(s, 4, p, 78)
            beat = s
            for p, d in mel[b]:
                horns.note(beat, d * .95, p, 96); brass.note(beat, d * .95, p - 12, 84); beat += d
            for i in range(12):
                strs.note(s + i / 3, .25, base + 12 + [0, 7, 12][i % 3], 76 if i % 3 == 0 else 58)
            tuba.note(s, 1, base - 12 if base - 12 >= 31 else base, 90); tuba.note(s + 2, 1, base - 5 if base - 5 >= 31 else base + 7, 84)
            timp.note(s, .4, base if base <= 50 else base - 12, 100); timp.note(s + 2, .4, base if base <= 50 else base - 12, 90)
            # march snare: four on the floor with ruffs
            for off in (0, 1, 2, 3): dr.note(s + off, .2, 38, 92 if off in (0, 2) else 78)
            for off in (.66, 2.66, 3.33): dr.note(s + off, .15, 38, 64)
            dr.note(s, .25, 36, 108); dr.note(s + 2, .25, 36, 96)
            if b % 4 == 0: dr.note(s, 2, 57, 92)
        return [choir, brass, horns, strs, timp, tuba, dr]

    return "e", 88, ambient, tension, combat

def main():
    os.makedirs(C.OUT, exist_ok=True)
    td = tempfile.mkdtemp()
    makers = {"b": suite_b, "c": suite_c, "d": suite_d, "e": suite_e}
    want = sys.argv[1:] or list(makers)
    for make in (makers[k] for k in want):
        tag, bpm, amb, ten, com = make()
        C.BPM = bpm
        loop = int(round(BARS * 4 * 60 / bpm * SR))
        for name, fn, gain, peak in (("ambient", amb, 0.5, 0.55), ("tension", ten, 0.5, 0.6), ("combat", com, 0.45, 0.75)):
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
