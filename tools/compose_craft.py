#!/usr/bin/env python3
"""Three fantasy score suites for Commander Craft (Warcraft-flavoured, all original), each with
ambient / tension / combat stems that loop together (32 bars):

  Suite F "Banners of Dawn":    D major, 92 bpm - lute, recorder and harp; a noble brass march.
  Suite G "Drums of the Warband": D minor (dorian), 96 bpm - pan flute and low hums; war drums and horns.
  Suite H "Moonlit Grove":       E minor, 72 bpm - harp, flute and choir; a sweeping strings-and-horns climax.

Uses the helpers in compose.py / compose_suites.py. Run: python3 tools/compose_craft.py [f g h]"""
import os, sys, random, tempfile
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compose as C
import compose_suites as S

BARS = 32
SR = C.SR
PC = S.PC


def chord(name):
    return S.chord(name)


def vce(pcs, lo, hi):
    return S.vce(pcs, lo, hi)


def melody(prog, tonic, rng, lo, hi, style, mode):
    """like compose_suites.gen_melody, with a choice of mode (major / dorian / minor)"""
    steps = {"major": [0, 2, 4, 5, 7, 9, 11], "dorian": [0, 2, 3, 5, 7, 9, 10], "minor": [0, 2, 3, 5, 7, 8, 10],
             "phrygdom": [0, 1, 4, 5, 7, 8, 10], "lydian": [0, 2, 4, 6, 7, 9, 11]}[mode]
    sc = [(tonic + s) % 12 for s in steps]
    cells = {
        "noble": [[1.5, .5, 2], [1, 1, 1, 1], [2, 1, 1], [3, 1], [1, .5, .5, 2], [2, 2]],
        "tribal": [[1, 1, 2], [.5, .5, 1, 2], [1.5, .5, 1, 1], [2, 1, 1], [1, 1, 1, 1]],
        "lyric": [[3, 1], [2, 2], [1.5, .5, 2], [4], [2, 1, 1]],
    }[style]
    pitches = [p for p in range(lo, hi + 1) if p % 12 in sc]

    def phrase(bars, start, lift=0):
        out, cur = [], start
        for b in bars:
            _, ct = chord(prog[b])
            cell = cells[rng.randrange(len(cells))]
            notes = []
            for i, d in enumerate(cell):
                if i == 0:
                    cands = [p for p in pitches if p % 12 in ct] or pitches
                    cur = min(cands, key=lambda p: abs(p - (cur + lift)) + rng.random() * 2)
                else:
                    step = rng.choice([-2, -1, 1, 1, 2, -1, 3])
                    idx = min(range(len(pitches)), key=lambda k: abs(pitches[k] - cur))
                    cur = pitches[max(0, min(len(pitches) - 1, idx + step))]
                notes.append((cur, d))
            out.append(notes)
        return out

    mid = (lo + hi) // 2
    A = phrase(range(0, 8), mid)
    B = phrase(range(8, 16), mid + 3)
    A2 = [list(bar) for bar in A[:6]] + phrase(range(22, 24), A[5][-1][0])
    tonic_p = min([p for p in pitches if p % 12 == tonic], key=lambda p: abs(p - mid))
    A2[7] = [(tonic_p, 4)]
    Cl = phrase(range(24, 32), mid + 5, lift=2)
    return A + B + A2 + Cl


# ---------------------------------------------------------------------------- Suite F
def suite_f():
    rng = random.Random(1515)
    prog = ["D", "G", "D", "A", "Bm", "G", "Em", "A", "D", "C", "G", "D", "Bm", "Em", "A", "A",
            "D", "G", "D", "A", "G", "D", "Em", "A", "Bm", "G", "D", "A", "G", "C", "A", "A"]
    mel = melody(prog, PC["D"], rng, 62, 81, "noble", "major")

    def ambient():
        lute = C.Track(0, 24, "lute"); rec = C.Track(1, 74, "recorder"); pad = C.Track(2, 49, "strings")
        harp = C.Track(3, 46, "harp"); bass = C.Track(4, 32, "bass")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            for p in vce(pcs, 54, 69)[:3]: pad.note(s, 4, p, 30)
            bass.note(s, 2, 38 + (r - 38) % 12, 40); bass.note(s + 2, 2, 38 + (r - 38) % 12 + (7 if (r + 7) % 12 in pcs else 0), 34)
            arp = vce(pcs, 50, 74)
            for i in range(8):   # lute picking pattern
                lute.note(s + i * .5, .7, arp[[0, 2, 1, 3, 2, 4, 3, 1][i] % len(arp)], 46 if i % 2 == 0 else 36)
            if b % 8 in (1, 2, 3, 5, 6):
                beat = s
                for p, d in mel[b]:
                    rec.note(beat, d, p, 44); beat += d
            if b % 4 == 3:
                for i, p in enumerate(vce(pcs, 69, 88)[:5]): harp.note(s + 2 + i * .4, 1.2, p, 32)
        return [lute, rec, pad, harp, bass]

    def tension():
        pizz = C.Track(0, 45, "pizz"); horn = C.Track(1, 60, "horn"); low = C.Track(2, 42, "cello")
        trem = C.Track(3, 44, "trem"); sn = C.Track(9, 0, "drums")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 38 + (r - 38) % 12
            for i in range(8):
                p = base + [0, 7, 12, 7, 0, 7, 12, 16][i]
                if p % 12 not in pcs: p = base + 12
                pizz.note(s + i * .5, .4, p + 12, 60 if i % 4 == 0 else 46)
            low.note(s, 4, base, 56)
            for p in vce(pcs, 69, 78)[:2]: trem.note(s, 4, p, 34 + (b % 8) * 3)
            if b % 4 == 1:
                ct = vce(pcs, 55, 69)
                horn.note(s, 1.5, ct[0], 54); horn.note(s + 1.5, .5, ct[1 % len(ct)], 52); horn.note(s + 2, 2, ct[-1], 58)
            # a distant snare roll building through each 8 bars
            for i in range(4): sn.note(s + i, .15, 38, 26 + (b % 8) * 4)
        return [pizz, horn, low, trem, sn]

    def combat():
        strs = C.Track(0, 48, "strings"); brass = C.Track(1, 61, "brass"); tpt = C.Track(2, 56, "tpt")
        horns = C.Track(3, 60, "horns"); timp = C.Track(4, 47, "timp"); bones = C.Track(5, 57, "bones")
        dr = C.Track(9, 0, "drums")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 38 + (r - 38) % 12
            beat = s
            for p, d in mel[b]:
                tpt.note(beat, d * .95, p, 96); horns.note(beat, d * .95, p - 12, 88); beat += d
            for p in vce(pcs, 50, 62)[:3]:
                brass.note(s, 1.5, p, 86); brass.note(s + 2, 1.5, p, 80)
            bones.note(s, 2, base if base >= 40 else base + 12, 86); bones.note(s + 2, 2, base + 7 if base + 7 <= 52 else base - 5, 82)
            arp = vce(pcs, 50, 74)
            for i in range(16): strs.note(s + i * .25, .2, arp[[0, 1, 2, 3, 2, 1, 2, 4][i % 8] % len(arp)], 72 if i % 4 == 0 else 54)
            timp.note(s, .4, base if base >= 40 else base + 12, 100); timp.note(s + 2, .4, base + 7 if base + 7 <= 52 else base, 88)
            # a field march: snare on every beat with flams, bass drum on 1 and 3
            for off in (0, 1, 2, 3): dr.note(s + off, .2, 38, 90 if off in (0, 2) else 74)
            for off in (.5, 1.5, 2.5, 3.75): dr.note(s + off, .1, 38, 52)
            dr.note(s, .25, 36, 104); dr.note(s + 2, .25, 36, 92)
            if b % 8 == 0: dr.note(s, 2, 49, 96)
        return [strs, brass, tpt, horns, timp, bones, dr]

    return "f", 92, ambient, tension, combat


# ---------------------------------------------------------------------------- Suite G
def suite_g():
    rng = random.Random(2626)
    prog = ["Dm", "C", "Dm", "Am", "Dm", "G", "C", "Am", "F", "C", "Dm", "Dm", "Bb", "C", "A", "A",
            "Dm", "C", "Dm", "Am", "G", "Dm", "C", "Dm", "Bb", "F", "C", "Dm", "Bb", "C", "A", "A"]
    mel = melody(prog, PC["D"], rng, 60, 77, "tribal", "dorian")

    def ambient():
        pan = C.Track(0, 75, "pan flute"); hum = C.Track(1, 53, "voice oohs"); drone = C.Track(2, 42, "cello")
        tom = C.Track(9, 0, "drums"); bass = C.Track(3, 32, "bass")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            drone.note(s, 4, 38 if r != 9 else 45, 40)
            for p in vce(pcs, 50, 62)[:2]: hum.note(s, 4, p, 34)
            bass.note(s, 4, 38 + (r - 38) % 12 - 12 if 38 + (r - 38) % 12 - 12 >= 28 else 38 + (r - 38) % 12, 34)
            if b % 4 in (1, 2):
                beat = s
                for p, d in mel[b]:
                    pan.note(beat, d, p + 12, 42); beat += d
            # a far-off heartbeat drum
            tom.note(s, .3, 41, 40); tom.note(s + .75, .3, 41, 30)
            if b % 2 == 1: tom.note(s + 2.5, .3, 43, 30)
        return [pan, hum, drone, tom, bass]

    def tension():
        low = C.Track(0, 48, "low strings"); horn = C.Track(1, 60, "horn"); bsn = C.Track(2, 70, "bassoon")
        tom = C.Track(9, 0, "drums"); trem = C.Track(3, 44, "trem")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 38 + (r - 38) % 12
            for off in (0, .5, 1.5, 2, 2.5, 3.5): low.note(s + off, .3, base, 70 if off in (0, 2) else 54)
            for off, nn, v in ((0, 41, 80), (.75, 43, 56), (1.5, 41, 64), (2, 45, 74), (2.75, 43, 56), (3.5, 41, 62)):
                tom.note(s + off, .25, nn, v)
            if b % 4 == 2:
                ct = vce(pcs, 50, 62)
                horn.note(s, 3, ct[0], 60); bsn.note(s + 3, 1, base + 12, 54)
            for p in vce(pcs, 62, 72)[:2]: trem.note(s, 4, p, 32 + (b % 8) * 3)
        return [low, horn, bsn, tom, trem]

    def combat():
        choir = C.Track(0, 52, "choir"); brass = C.Track(1, 61, "brass"); horns = C.Track(2, 60, "horns")
        strs = C.Track(3, 48, "strings"); taiko = C.Track(4, 116, "taiko"); tuba = C.Track(5, 58, "tuba")
        dr = C.Track(9, 0, "drums")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 38 + (r - 38) % 12
            # war chant: the choir barks on the beats
            for off in (0, 1, 2, 3):
                for p in vce(pcs, 50, 62)[:3]: choir.note(s + off, .6, p, 90 if off in (0, 2) else 70)
            beat = s
            for p, d in mel[b]:
                horns.note(beat, d * .95, p, 96); brass.note(beat, d * .95, p - 12, 88); beat += d
            tuba.note(s, 1, base - 12 if base - 12 >= 28 else base, 92); tuba.note(s + 1.5, .5, base - 12 if base - 12 >= 28 else base, 80)
            tuba.note(s + 2, 2, base - 5 if base - 5 >= 28 else base + 7, 86)
            for i in range(8): strs.note(s + i * .5, .35, base + 12 + [0, 0, 7, 0, 10, 0, 7, 3][i], 78 if i % 2 == 0 else 60)
            # war drums
            for off, v in ((0, 120), (.5, 80), (1, 100), (1.75, 80), (2, 115), (2.5, 82), (3, 104), (3.5, 90)):
                taiko.note(s + off, .3, 48, v)
            for off, nn, v in ((0, 41, 104), (1, 43, 92), (2, 41, 104), (2.5, 45, 84), (3, 43, 94), (3.25, 45, 80), (3.5, 41, 90)):
                dr.note(s + off, .25, nn, v)
            dr.note(s, .25, 36, 112)
            if b % 8 == 7:
                for i in range(8): dr.note(s + 2 + i * .25, .25, 45, 60 + i * 7)
        return [choir, brass, horns, strs, taiko, tuba, dr]

    return "g", 96, ambient, tension, combat


# ---------------------------------------------------------------------------- Suite H
def suite_h():
    rng = random.Random(3737)
    prog = ["Em", "C", "G", "D", "Em", "Am", "B", "B", "C", "G", "Am", "Em", "C", "D", "B", "B",
            "Em", "C", "G", "D", "Am", "Em", "B", "Em", "C", "Am", "Em", "D", "C", "D", "B", "B"]
    mel = melody(prog, PC["E"], rng, 64, 83, "lyric", "minor")

    def ambient():
        harp = C.Track(0, 46, "harp"); flute = C.Track(1, 73, "flute"); choir = C.Track(2, 52, "choir")
        cel = C.Track(3, 8, "celesta"); bass = C.Track(4, 43, "contrabass")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            for p in vce(pcs, 55, 71)[:3]: choir.note(s, 4, p, 28)
            bass.note(s, 4, 28 + (r - 28) % 12 + 12, 34)
            arp = vce(pcs, 52, 84)
            for i in range(12):   # rolling harp in triplets
                harp.note(s + i / 3, .9, arp[(i + b) % len(arp)], 36 if i % 3 == 0 else 26)
            if b % 8 in (2, 3, 4, 5):
                beat = s
                for p, d in mel[b]:
                    flute.note(beat, d, p + 12, 42); beat += d
            if b % 8 == 7:
                for i, p in enumerate(vce(pcs, 79, 91)[:4]): cel.note(s + i * .5, 1.5, p, 30)
        return [harp, flute, choir, cel, bass]

    def tension():
        trem = C.Track(0, 44, "trem"); oboe = C.Track(1, 68, "oboe"); low = C.Track(2, 42, "cello")
        timp = C.Track(3, 47, "timp"); harp = C.Track(4, 46, "harp")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 40 + (r - 40) % 12
            for p in vce(pcs, 55, 76)[:3]: trem.note(s, 4, p, 40 + (b % 8) * 3)
            low.note(s, 2, base, 58); low.note(s + 2, 2, base + 7 if base + 7 <= 52 else base - 5, 52)
            timp.note(s, .6, base if base >= 40 else base + 12, 62)
            if b % 2 == 0:
                beat = s
                for p, d in mel[b]:
                    oboe.note(beat, d, p, 46); beat += d
            arp = vce(pcs, 64, 88)
            for i in range(4): harp.note(s + i, .8, arp[(i * 2 + b) % len(arp)], 30)
        return [trem, oboe, low, timp, harp]

    def combat():
        strs = C.Track(0, 48, "strings"); horns = C.Track(1, 60, "horns"); choir = C.Track(2, 52, "choir")
        brass = C.Track(3, 61, "brass"); timp = C.Track(4, 47, "timp"); fl = C.Track(5, 73, "flute")
        dr = C.Track(9, 0, "drums")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = 40 + (r - 40) % 12
            for p in vce(pcs, 55, 72)[:3]: choir.note(s, 4, p, 80)
            beat = s
            for p, d in mel[b]:
                horns.note(beat, d * .95, p, 96); fl.note(beat, d * .95, p + 12, 70); beat += d
            for p in vce(pcs, 47, 59)[:2]: brass.note(s, 2, p, 84); brass.note(s + 2, 2, p, 80)
            arp = vce(pcs, 52, 76)
            for i in range(12): strs.note(s + i / 3, .3, arp[[0, 1, 2, 3, 2, 1][i % 6] % len(arp)], 76 if i % 3 == 0 else 56)
            for off in (0, .66, 1.33, 2, 3): timp.note(s + off, .4, base if base >= 40 else base + 12, 98 if off in (0, 2) else 76)
            dr.note(s, .25, 36, 104); dr.note(s + 2, .25, 36, 94)
            if b % 4 == 0: dr.note(s, 2, 49, 92)
            if b % 8 == 7:
                for i in range(6): dr.note(s + 2 + i / 3, .2, 38, 64 + i * 8)
        return [strs, horns, choir, brass, timp, fl, dr]

    return "h", 72, ambient, tension, combat


def lo(p, floor=28):
    while p > floor + 11: p -= 12
    while p < floor: p += 12
    return p


# ---------------------------------------------------------------------------- Suite I
def suite_i():
    """Frostpeak Vigil: A minor, 84 bpm - bells, celesta and a low choir in the snow; war horns."""
    rng = random.Random(4848)
    prog = ["Am", "F", "C", "G", "Am", "Dm", "E", "E", "F", "C", "G", "Am", "Dm", "Am", "E", "E",
            "Am", "F", "C", "G", "F", "Dm", "E", "Am", "F", "G", "Am", "Dm", "F", "G", "E", "E"]
    mel = melody(prog, PC["A"], rng, 64, 81, "lyric", "minor")

    def ambient():
        bell = C.Track(0, 14, "tubular bells"); cel = C.Track(1, 8, "celesta"); choir = C.Track(2, 52, "choir")
        pad = C.Track(3, 49, "strings"); bass = C.Track(4, 43, "contrabass")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            for p in vce(pcs, 48, 60)[:3]: choir.note(s, 4, p, 30)
            for p in vce(pcs, 57, 72)[:2]: pad.note(s, 4, p, 24)
            bass.note(s, 4, lo(r, 33), 36)
            arp = vce(pcs, 72, 91)
            for i in range(4): cel.note(s + i + .5 * (b % 2), .9, arp[(i * 2 + b) % len(arp)], 30)
            if b % 4 == 0: bell.note(s, 3, vce(pcs, 60, 72)[0], 40)
            if b % 8 in (4, 5, 6):
                beat = s
                for p, d in mel[b]:
                    cel.note(beat, d, p + 12, 34); beat += d
        return [bell, cel, choir, pad, bass]

    def tension():
        trem = C.Track(0, 44, "trem"); horn = C.Track(1, 60, "horn"); low = C.Track(2, 42, "cello")
        timp = C.Track(3, 47, "timp"); bell = C.Track(4, 14, "bells")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = lo(r, 40)
            for p in vce(pcs, 57, 72)[:3]: trem.note(s, 4, p, 36 + (b % 8) * 3)
            for off in (0, 1.5, 2, 3.5): low.note(s + off, .45, base, 66 if off in (0, 2) else 52)
            timp.note(s, .5, base, 58 + (b % 4) * 6)
            if b % 4 == 3:
                ct = vce(pcs, 52, 64)
                horn.note(s, 2, ct[0], 58); horn.note(s + 2, 2, ct[-1], 62)
            if b % 8 == 0: bell.note(s, 3, vce(pcs, 64, 76)[0], 50)
        return [trem, horn, low, timp, bell]

    def combat():
        strs = C.Track(0, 48, "strings"); horns = C.Track(1, 60, "horns"); choir = C.Track(2, 52, "choir")
        brass = C.Track(3, 61, "brass"); timp = C.Track(4, 47, "timp"); bell = C.Track(5, 14, "bells")
        dr = C.Track(9, 0, "drums")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = lo(r, 40)
            for p in vce(pcs, 50, 64)[:3]: choir.note(s, 2, p, 86); choir.note(s + 2, 2, p, 80)
            beat = s
            for p, d in mel[b]:
                horns.note(beat, d * .95, p, 98); beat += d
            for p in vce(pcs, 45, 57)[:2]: brass.note(s, 1, p, 88); brass.note(s + 1.5, .5, p, 76); brass.note(s + 2, 2, p, 84)
            for i in range(16): strs.note(s + i * .25, .2, base + 12 + [0, 7, 12, 7][i % 4], 74 if i % 4 == 0 else 56)
            for off in (0, 1, 2, 2.5, 3): timp.note(s + off, .3, base, 104 if off in (0, 2) else 80)
            dr.note(s, .25, 36, 110); dr.note(s + 2, .25, 36, 100)
            for off in (1, 3): dr.note(s + off, .2, 38, 92)
            if b % 4 == 0: bell.note(s, 2, vce(pcs, 64, 76)[0], 70); dr.note(s, 2, 49, 90)
        return [strs, horns, choir, brass, timp, bell, dr]

    return "i", 84, ambient, tension, combat


# ---------------------------------------------------------------------------- Suite J
def suite_j():
    """Caravan of Sands: D (phrygian dominant), 100 bpm - plucked strings, reed and hand drums."""
    rng = random.Random(5959)
    prog = ["D", "Eb", "D", "Cm", "D", "Gm", "Eb", "D", "Gm", "Cm", "D", "D", "Eb", "Cm", "D", "D",
            "D", "Eb", "D", "Cm", "Gm", "Eb", "D", "D", "Cm", "Gm", "Eb", "D", "Eb", "Cm", "D", "D"]
    mel = melody(prog, PC["D"], rng, 62, 79, "tribal", "phrygdom")

    def ambient():
        oud = C.Track(0, 25, "steel guitar"); reed = C.Track(1, 68, "oboe"); drone = C.Track(2, 42, "cello")
        hand = C.Track(9, 0, "drums"); pad = C.Track(3, 89, "warm pad")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            drone.note(s, 4, 38, 38); pad.note(s, 4, vce(pcs, 57, 69)[0], 26)
            arp = vce(pcs, 50, 69)
            for i, off in enumerate((0, .75, 1.5, 2, 2.75, 3.5)): oud.note(s + off, .5, arp[(i + b) % len(arp)], 44 if i % 3 == 0 else 34)
            if b % 8 in (2, 3, 6, 7):
                beat = s
                for p, d in mel[b]:
                    reed.note(beat, d, p, 40); beat += d
            for off, nn, v in ((0, 60, 44), (.75, 61, 30), (1.5, 60, 34), (2, 61, 40), (3, 60, 32)): hand.note(s + off, .2, nn, v)
        return [oud, reed, drone, hand, pad]

    def tension():
        low = C.Track(0, 48, "low strings"); oud = C.Track(1, 25, "guitar"); horn = C.Track(2, 60, "horn")
        dr = C.Track(9, 0, "drums"); trem = C.Track(3, 44, "trem")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = lo(r, 38)
            for off in (0, .75, 1.5, 2, 2.75, 3.5): low.note(s + off, .3, base, 70 if off in (0, 2) else 54)
            arp = vce(pcs, 62, 74)
            for i in range(8): oud.note(s + i * .5, .35, arp[(i * 3 + b) % len(arp)], 52 if i % 2 == 0 else 40)
            for off, nn, v in ((0, 64, 76), (.75, 63, 50), (1.5, 64, 62), (2, 62, 70), (2.75, 63, 50), (3.5, 64, 58)): dr.note(s + off, .2, nn, v)
            for p in vce(pcs, 62, 72)[:2]: trem.note(s, 4, p, 30 + (b % 8) * 3)
            if b % 8 == 4: horn.note(s, 4, vce(pcs, 50, 62)[0], 58)
        return [low, oud, horn, dr, trem]

    def combat():
        strs = C.Track(0, 48, "strings"); brass = C.Track(1, 61, "brass"); reed = C.Track(2, 68, "oboe")
        horns = C.Track(3, 60, "horns"); taiko = C.Track(4, 116, "taiko"); tuba = C.Track(5, 58, "tuba")
        dr = C.Track(9, 0, "drums")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = lo(r, 38)
            beat = s
            for p, d in mel[b]:
                reed.note(beat, d * .95, p + 12, 92); horns.note(beat, d * .95, p, 90); beat += d
            for p in vce(pcs, 50, 62)[:3]: brass.note(s, .75, p, 90); brass.note(s + 1.5, .5, p, 78); brass.note(s + 2, 1.5, p, 86)
            tuba.note(s, 1.5, lo(r, 30), 92); tuba.note(s + 2, 1.5, lo(r + 7, 30), 86)
            for i in range(16): strs.note(s + i * .25, .2, base + 12 + [0, 1, 4, 1, 0, 1, 4, 7][i % 8], 76 if i % 4 == 0 else 56)
            for off, v in ((0, 118), (.75, 84), (1.5, 100), (2, 116), (2.75, 84), (3.5, 96)): taiko.note(s + off, .3, 48, v)
            for off, nn, v in ((0, 64, 100), (.5, 63, 70), (1, 62, 86), (1.5, 64, 80), (2, 64, 100), (2.5, 63, 70), (3, 62, 90), (3.25, 62, 76), (3.5, 64, 84)):
                dr.note(s + off, .2, nn, v)
            dr.note(s, .25, 36, 110)
            if b % 8 == 7:
                for i in range(8): dr.note(s + 2 + i * .25, .2, 62, 60 + i * 7)
        return [strs, brass, reed, horns, taiko, tuba, dr]

    return "j", 100, ambient, tension, combat


# ---------------------------------------------------------------------------- Suite K
def suite_k():
    """The Elven Watch: F (lydian), 80 bpm - harp, flutes and strings; a soaring horn theme."""
    rng = random.Random(6161)
    prog = ["F", "G", "Am", "F", "C", "G", "Dm", "C", "F", "G", "Em", "Am", "Dm", "G", "C", "C",
            "F", "G", "Am", "Em", "F", "C", "Dm", "G", "Am", "F", "G", "C", "F", "G", "C", "C"]
    mel = melody(prog, PC["F"], rng, 65, 84, "lyric", "lydian")

    def ambient():
        harp = C.Track(0, 46, "harp"); flute = C.Track(1, 73, "flute"); pad = C.Track(2, 49, "strings")
        cl = C.Track(3, 71, "clarinet"); bass = C.Track(4, 43, "contrabass")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            for p in vce(pcs, 55, 72)[:3]: pad.note(s, 4, p, 28)
            bass.note(s, 4, lo(r, 36), 34)
            arp = vce(pcs, 53, 86)
            for i in range(8): harp.note(s + i * .5, .9, arp[(i + b * 2) % len(arp)], 36 if i % 4 == 0 else 26)
            if b % 8 in (1, 2, 3, 5, 6):
                beat = s
                for p, d in mel[b]:
                    flute.note(beat, d, p + 12, 40); beat += d
            if b % 8 == 4:
                ct = vce(pcs, 60, 72)
                cl.note(s, 2, ct[0], 34); cl.note(s + 2, 2, ct[1 % len(ct)], 32)
        return [harp, flute, pad, cl, bass]

    def tension():
        trem = C.Track(0, 44, "trem"); horn = C.Track(1, 60, "horn"); low = C.Track(2, 42, "cello")
        harp = C.Track(3, 46, "harp"); timp = C.Track(4, 47, "timp")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = lo(r, 36)
            for p in vce(pcs, 60, 76)[:3]: trem.note(s, 4, p, 36 + (b % 8) * 3)
            low.note(s, 3, base + 12, 56); low.note(s + 3, 1, base + 19 if base + 19 <= 60 else base + 7, 50)
            arp = vce(pcs, 65, 89)
            for i in range(6): harp.note(s + i * 2 / 3, .8, arp[(i + b) % len(arp)], 32)
            if b % 4 == 2:
                beat = s
                for p, d in mel[b]:
                    horn.note(beat, d, p - 12, 50); beat += d
            if b % 2 == 1: timp.note(s + 3, .5, lo(r, 41), 56)
        return [trem, horn, low, harp, timp]

    def combat():
        strs = C.Track(0, 48, "strings"); horns = C.Track(1, 60, "horns"); fl = C.Track(2, 73, "flute")
        brass = C.Track(3, 61, "brass"); timp = C.Track(4, 47, "timp"); choir = C.Track(5, 52, "choir")
        dr = C.Track(9, 0, "drums")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = lo(r, 41)
            beat = s
            for p, d in mel[b]:
                horns.note(beat, d * .95, p, 100); fl.note(beat, d * .95, p + 12, 72); beat += d
            for p in vce(pcs, 55, 70)[:3]: choir.note(s, 4, p, 78)
            for p in vce(pcs, 48, 60)[:2]: brass.note(s, 1.5, p, 84); brass.note(s + 2, 2, p, 84)
            arp = vce(pcs, 53, 77)
            for i in range(12): strs.note(s + i / 3, .3, arp[[0, 1, 2, 3, 2, 1][i % 6] % len(arp)], 76 if i % 3 == 0 else 56)
            timp.note(s, .4, base, 100); timp.note(s + 2, .4, base, 90); timp.note(s + 3.33, .3, base, 76)
            dr.note(s, .25, 36, 100); dr.note(s + 2, .25, 36, 92)
            if b % 8 == 0: dr.note(s, 2, 49, 94)
        return [strs, horns, fl, brass, timp, choir, dr]

    return "k", 80, ambient, tension, combat


# ---------------------------------------------------------------------------- Suite L
def suite_l():
    """Siege of Ironhold: C minor, 108 bpm - low brass, male choir and the ring of hammers on anvils."""
    rng = random.Random(7272)
    prog = ["Cm", "Cm", "Ab", "Bb", "Cm", "Fm", "G", "G", "Ab", "Eb", "Bb", "Cm", "Fm", "Cm", "G", "G",
            "Cm", "Ab", "Eb", "Bb", "Fm", "Cm", "G", "Cm", "Ab", "Bb", "Cm", "Fm", "Ab", "Bb", "G", "G"]
    mel = melody(prog, PC["C"], rng, 55, 72, "noble", "minor")

    def ambient():
        low = C.Track(0, 52, "male choir"); bsn = C.Track(1, 70, "bassoon"); bass = C.Track(2, 43, "contrabass")
        anvil = C.Track(9, 0, "drums"); horn = C.Track(3, 60, "horn")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            for p in vce(pcs, 43, 55)[:3]: low.note(s, 4, p, 32)
            bass.note(s, 4, lo(r, 28), 38)
            # the forge: a slow hammer on the anvil
            anvil.note(s, .2, 67, 44); anvil.note(s + 2.5, .2, 67, 32)
            if b % 8 in (3, 4, 5):
                beat = s
                for p, d in mel[b]:
                    bsn.note(beat, d, p - 12, 40); beat += d
            if b % 8 == 7: horn.note(s, 4, vce(pcs, 48, 60)[0], 44)
        return [low, bsn, bass, anvil, horn]

    def tension():
        low = C.Track(0, 48, "low strings"); bones = C.Track(1, 57, "bones"); choir = C.Track(2, 52, "choir")
        dr = C.Track(9, 0, "drums"); timp = C.Track(3, 47, "timp")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = lo(r, 36)
            for i in range(8): low.note(s + i * .5, .35, base, 72 if i % 4 == 0 else 54)
            for p in vce(pcs, 48, 60)[:3]: choir.note(s, 4, p, 40 + (b % 8) * 3)
            if b % 4 == 3: bones.note(s, 2, base + 12, 64); bones.note(s + 2, 2, lo(r + 7, 36) + 12, 66)
            for off in (0, 1.5, 3): dr.note(s + off, .2, 67, 58)
            timp.note(s, .5, lo(r, 40), 64)
        return [low, bones, choir, dr, timp]

    def combat():
        strs = C.Track(0, 48, "strings"); brass = C.Track(1, 61, "brass"); bones = C.Track(2, 57, "bones")
        choir = C.Track(3, 52, "choir"); taiko = C.Track(4, 116, "taiko"); tuba = C.Track(5, 58, "tuba")
        dr = C.Track(9, 0, "drums")
        for b in range(BARS):
            s = b * 4; r, pcs = chord(prog[b])
            base = lo(r, 36)
            beat = s
            for p, d in mel[b]:
                bones.note(beat, d * .95, p, 100); brass.note(beat, d * .95, p + 12, 90); beat += d
            for p in vce(pcs, 48, 60)[:3]:
                for off in (0, 1, 2, 3): choir.note(s + off, .7, p, 88 if off in (0, 2) else 72)
            tuba.note(s, 1, lo(r, 28), 96); tuba.note(s + 1.5, .5, lo(r, 28), 80); tuba.note(s + 2, 2, lo(r + 7, 28), 90)
            for i in range(16): strs.note(s + i * .25, .2, base + 12 + [0, 0, 3, 0, 7, 0, 3, 0][i % 8], 78 if i % 4 == 0 else 58)
            for off, v in ((0, 120), (1, 96), (2, 118), (2.5, 84), (3, 100)): taiko.note(s + off, .3, 48, v)
            # hammers on anvils, on the off-beats
            for off in (.5, 1.5, 2.5, 3.5): dr.note(s + off, .15, 67, 84)
            dr.note(s, .25, 36, 112); dr.note(s + 2, .25, 36, 104)
            if b % 8 == 7:
                for i in range(8): dr.note(s + 2 + i * .25, .2, 38, 60 + i * 7)
        return [strs, brass, bones, choir, taiko, tuba, dr]

    return "l", 108, ambient, tension, combat


def main():
    os.makedirs(C.OUT, exist_ok=True)
    td = tempfile.mkdtemp()
    makers = {"f": suite_f, "g": suite_g, "h": suite_h, "i": suite_i, "j": suite_j, "k": suite_k, "l": suite_l}
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
