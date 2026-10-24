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
    steps = {"major": [0, 2, 4, 5, 7, 9, 11], "dorian": [0, 2, 3, 5, 7, 9, 10], "minor": [0, 2, 3, 5, 7, 8, 10]}[mode]
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


def main():
    os.makedirs(C.OUT, exist_ok=True)
    td = tempfile.mkdtemp()
    makers = {"f": suite_f, "g": suite_g, "h": suite_h}
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
