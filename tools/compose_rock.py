#!/usr/bin/env python3
"""Three rock / prog suites for Annihilation, each with ambient / tension / combat stems that
loop in sync, rendered with FluidSynth like the orchestral ones.

  _p "Thunder Run":    F# minor, 132 bpm, 4/4 - drum-heavy: hand drums in the calm, a full
                       power kit in the skirmish, double kick, tom runs and taiko in battle.
  _q "Steel Sky":      B minor, 112 bpm, 4/4 - lead-guitar-heavy: clean arpeggios, palm-muted
                       rhythm, then a bending, vibrato-laden lead with a harmony guitar.
  _r "Glass Mountain": E lydian, 168 bpm, 7/8 - a prog suite in the spirit of 70s symphonic
                       rock: twelve-string arpeggios, a busy picked bass, organ, a high choir
                       line, and a synth lead over church organ in battle.

Run: python3 tools/compose_rock.py [p q r]"""
import os, sys, random, tempfile
import numpy as np
import mido
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compose as C

SR = C.SR
PC = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6, "G": 7,
      "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11}


def chord(name):
    """'F#m', 'A', 'E/G#', 'F#/E', 'Bsus' -> (bass pc, chord pcs)"""
    bass = None
    if "/" in name:
        name, b = name.split("/")
        bass = PC[b]
    kind = "maj"
    if name.endswith("sus"): kind, name = "sus", name[:-3]
    elif name.endswith("m"): kind, name = "min", name[:-1]
    r = PC[name]
    third = {"maj": 4, "min": 3, "sus": 5}[kind]
    pcs = [r, (r + third) % 12, (r + 7) % 12]
    return (r if bass is None else bass), pcs


def vce(pcs, lo, hi):
    return sorted(p for p in range(lo, hi + 1) if p % 12 in pcs)


def near(pc, around):
    """the pitch with pitch class pc closest to `around`"""
    return min((p for p in range(around - 6, around + 7) if p % 12 == pc), key=lambda p: abs(p - around))


class T(C.Track):
    """a Track that can also bend (whole-step range by default) and change kits"""
    def bend(self, beat, val):
        self.ev.append((int(beat * C.TPB), 0, mido.Message("pitchwheel", channel=self.ch, pitch=int(val))))
    def kit(self, prog):
        self.ev.append((0, -1, mido.Message("program_change", channel=9, program=prog)))
    def vib(self, beat, dur, depth=900, rate=5.5, bpm=120):
        """finger vibrato as a wobble of the pitch wheel"""
        steps = max(2, int(dur * 8))
        for k in range(steps + 1):
            t = beat + dur * k / steps
            secs = (t - beat) * 60 / bpm
            self.bend(t, depth * np.sin(2 * np.pi * rate * secs) * min(1, k / 3))
        self.bend(beat + dur, 0)


def kick(dr, at, v=110): dr.note(at, .2, 36, v)
def snare(dr, at, v=100): dr.note(at, .2, 38, v)
def hat(dr, at, v=60, open_=False): dr.note(at, .2, 46 if open_ else 42, v)
def crash(dr, at, v=104): dr.note(at, 2, 49, v)
TOMS = [50, 48, 47, 45, 43, 41]   # high to floor


def tom_run(dr, start, n, step=.25, v0=80):
    for i in range(n):
        dr.note(start + i * step, step, TOMS[min(len(TOMS) - 1, i * len(TOMS) // n)], v0 + i * 3)


# ------------------------------------------------------------------------------ Thunder Run
def suite_p():
    bpm, bar, bars = 132, 4, 64
    prog = ["F#m", "D", "A", "E", "F#m", "D", "Bm", "C#", "D", "E", "F#m", "F#m", "Bm", "D", "C#", "C#",
            "F#m", "D", "A", "E", "Bm", "D", "C#", "F#m", "D", "E", "F#m", "F#m", "Bm", "D", "C#", "C#"]
    # second time round: a darker turn (Bm and G under it) before the home stretch
    prog = prog + ["Bm", "G", "D", "A", "Bm", "G", "C#", "C#", "F#m", "D", "A", "E", "F#m", "D", "Bm", "C#",
                   "D", "E", "F#m", "F#m", "Bm", "D", "C#", "F#m", "D", "E", "F#m", "F#m", "Bm", "D", "C#", "C#"]
    # a short shouty hook (beat offset, length, scale step from F#4 = 66)
    hook = [(0, .75, 66), (.75, .75, 69), (1.5, .5, 71), (2, 1, 73), (3, .5, 71), (3.5, .5, 69)]
    hook2 = [(0, .75, 73), (.75, .75, 74), (1.5, .5, 73), (2, 1, 71), (3, 1, 68)]

    def ambient():
        pad = T(0, 89, "warm pad"); bass = T(1, 33, "bass"); vib = T(2, 11, "vibes")
        dr = T(9, 0, "hand drums"); dr.kit(0)
        for b in range(bars):
            s = b * bar; r, pcs = chord(prog[b])
            for p in vce(pcs, 54, 69)[:3]: pad.note(s, 4, p, 38)
            low = 30 + (r - 30) % 12
            bass.note(s, 1.5, low + 12, 50); bass.note(s + 2.5, 1, low + 12, 40)
            # congas and bongos in a rolling 16th figure, ghosted
            pat = [(0, 63, 62), (.5, 64, 40), (.75, 62, 36), (1, 63, 50), (1.5, 64, 46), (2, 62, 54),
                   (2.5, 63, 44), (2.75, 64, 34), (3, 60, 50), (3.25, 61, 38), (3.5, 62, 46)]
            for off, nn, v in pat: dr.note(s + off, .25, nn, v + (6 if b % 4 == 3 else 0))
            dr.note(s, .3, 41, 52)                     # soft floor tom pulse on 1
            if b % 4 == 3: tom_run(dr, s + 3, 4, .25, 44)
            if b % 8 in (4, 5):
                for off, d, p in hook: vib.note(s + off, d, p + 12, 40)
        return [pad, bass, vib, dr]

    def tension():
        bass = T(0, 34, "picked bass"); gtr = T(1, 29, "muted gtr"); taiko = T(2, 116, "taiko")
        dr = T(9, 0, "kit"); dr.kit(16)
        for b in range(bars):
            s = b * bar; r, pcs = chord(prog[b])
            low = 30 + (r - 30) % 12
            for i in range(8): bass.note(s + i * .5, .4, low + 12, 84 if i % 2 == 0 else 70)
            for i in range(16):   # palm-muted chug, accents on the 3-3-2
                acc = i in (0, 3, 6, 8, 11, 14)
                gtr.note(s + i * .25, .14, low + 24, 74 if acc else 46)
            # groove: kick on 1, the and of 2, 3; snare 2 and 4; 16th hats with an open one
            for off in (0, 1.5, 2, 2.75): kick(dr, s + off, 108 if off == 0 else 92)
            for off in (1, 3): snare(dr, s + off, 104)
            for i in range(16): hat(dr, s + i * .25, 70 if i % 2 == 0 else 46, open_=(i == 14))
            if b % 2 == 1: snare(dr, s + 3.75, 52)
            if b % 4 == 3:
                tom_run(dr, s + 2, 8, .25, 80)
            if b % 8 == 0: crash(dr, s)
            taiko.note(s, .5, 45, 80)
        return [bass, gtr, taiko, dr]

    def combat():
        pw = T(0, 30, "power chords"); lead = T(1, 81, "saw lead"); taiko = T(2, 116, "taiko")
        brass = T(3, 61, "brass"); dr = T(9, 0, "kit"); dr.kit(16)
        for b in range(bars):
            s = b * bar; r, pcs = chord(prog[b])
            low = 30 + (r - 30) % 12 + 12
            # power chord stabs on the 3-3-2
            for off, d in ((0, .6), (.75, .6), (1.5, .4), (2, .6), (2.75, .6), (3.5, .4)):
                for p in (low, low + 7, low + 12): pw.note(s + off, d, p, 100 if off in (0, 2) else 86)
            if (b % 8 < 4 or 24 <= b % 32) and not (32 <= b < 40):
                ph = hook if b % 2 == 0 else hook2
                up = 12 if b >= 48 else 0
                for off, d, p in ph:
                    lead.note(s + off, d * .95, p + up, 92); brass.note(s + off, d * .95, p - 12, 78)
            # double kick 16ths, snare backbeat, ride; big tom phrases every other bar
            for i in range(16): kick(dr, s + i * .25, 100 if i % 4 == 0 else 78)
            for off in (1, 3): snare(dr, s + off, 116)
            for i in range(8): dr.note(s + i * .5, .2, 51 if b % 16 < 8 else 42, 76)
            if b % 2 == 1:
                tom_run(dr, s + 2, 8, .25, 88)
            if 24 <= b < 28 or 40 <= b < 44 or b >= 60:   # a drum break: snare and tom triplets rolling round the kit
                for i in range(12):
                    dr.note(s + i / 3, .2, TOMS[i % 6], 96 + (i % 3) * 6)
            if b % 4 == 0: crash(dr, s, 112); dr.note(s, 2, 57, 92)
            for off, v in ((0, 118), (1.5, 96), (2, 108), (3, 100), (3.5, 92)):
                taiko.note(s + off, .3, 45 if off == 0 else 48, v)
        return [pw, lead, taiko, brass, dr]

    return "p", bpm, bar, bars, ambient, tension, combat


# ------------------------------------------------------------------------------ Steel Sky
def suite_q():
    bpm, bar, bars = 112, 4, 64
    prog = ["Bm", "G", "D", "A", "Bm", "G", "Em", "F#", "G", "A", "Bm", "Bm", "Em", "G", "F#", "F#",
            "Bm", "G", "D", "A", "Em", "Bm", "F#", "Bm", "G", "A", "D", "Bm", "Em", "G", "F#", "F#"]
    # second half: a lift to the relative major, then back home
    prog = prog + ["D", "A", "G", "D", "Em", "G", "A", "A", "D", "A", "Bm", "G", "Em", "A", "F#", "F#",
                   "Bm", "G", "D", "A", "Em", "Bm", "F#", "Bm", "G", "A", "D", "Bm", "Em", "G", "F#", "F#"]
    rng = random.Random(1972)
    PENT = [11, 2, 4, 6, 9]                 # B minor pentatonic
    SCALE = [11, 1, 2, 4, 6, 7, 9]          # B natural minor
    lo, hi = 59, 86

    def scale_for(b, a, z):
        sc = [10 if c == 9 else c for c in SCALE] if prog[b] == "F#" else SCALE
        return [p for p in range(a, z + 1) if p % 12 in sc]

    def lead_line():
        """per bar: list of (offset, dur, pitch, bend) - melodic phrases that breathe, with
        16th-note pentatonic runs at the ends of phrases and whole-step bends into long notes"""
        pent = [p for p in range(lo, hi + 1) if p % 12 in PENT]
        scale = [p for p in range(lo, hi + 1) if p % 12 in SCALE]
        out, cur = [], 71
        rhythms = [[(0, 1.5), (1.5, .5), (2, 2)], [(0, .5), (.5, .5), (1, 1), (2, 1.5), (3.5, .5)],
                   [(0, 3), (3, .5), (3.5, .5)], [(0, 1), (1, 1), (2, .5), (2.5, .5), (3, 1)]]
        for b in range(bars):
            _, pcs = chord(prog[b])
            scale = scale_for(b, lo, hi)
            notes = []
            phrase_end = b % 4 == 3
            rh = rhythms[rng.randrange(len(rhythms))] if not phrase_end else [(0, 2)]
            for i, (off, d) in enumerate(rh):
                if i == 0:
                    cands = [p for p in scale if p % 12 in pcs]
                    lift = 3 if b % 32 >= 24 else (1 if b % 32 >= 16 else 0)
                    cur = min(cands, key=lambda p: abs(p - cur - lift) + rng.random() * 3)
                else:
                    idx = min(range(len(scale)), key=lambda k: abs(scale[k] - cur))
                    cur = scale[max(0, min(len(scale) - 1, idx + rng.choice([-2, -1, 1, 1, 2])))]
                bend = d >= 1.5 and rng.random() < .55
                notes.append((off, d, cur, bend))
            if phrase_end:   # a fast run up (or down) the pentatonic box to finish the phrase
                idx = min(range(len(pent)), key=lambda k: abs(pent[k] - cur))
                up = idx < len(pent) - 7 and rng.random() < .65
                for k in range(8):
                    j = max(0, min(len(pent) - 1, idx + (k + 1 if up else -(k + 1))))
                    notes.append((2 + k * .25, .25, pent[j], False))
                cur = pent[j]
            out.append(notes)
        return out

    line = lead_line()

    def ambient():
        gtr = T(0, 27, "clean gtr"); bass = T(1, 35, "fretless"); pad = T(2, 89, "pad")
        dr = T(9, 0, "kit"); dr.kit(32)
        gtr.cc(0, 93, 90)   # chorus
        for b in range(bars):
            s = b * bar; r, pcs = chord(prog[b])
            for p in vce(pcs, 54, 69)[:3]: pad.note(s, 4, p, 30)
            low = 35 + (r - 35) % 12
            bass.note(s, 3, low, 52); bass.note(s + 3, 1, low + 7 if (r + 7) % 12 in pcs else low + 12, 40)
            arp = vce(pcs + [(r + 2) % 12], 59, 79)       # add the 9th for that open ring
            order = [0, 2, 4, 3, 1, 3, 4, 2]
            for i in range(8): gtr.note(s + i * .5, 1.2, arp[order[i] % len(arp)], 52 if i % 4 == 0 else 40)
            dr.note(s, .2, 36, 44); dr.note(s + 2, .2, 37, 40)
            for i in range(4): dr.note(s + i, .2, 51, 34)
        return [gtr, bass, pad, dr]

    def tension():
        rhy = T(0, 30, "rhythm gtr"); bass = T(1, 34, "picked bass"); org = T(2, 16, "organ")
        dr = T(9, 0, "kit"); dr.kit(16)
        for b in range(bars):
            s = b * bar; r, pcs = chord(prog[b])
            low = 35 + (r - 35) % 12
            for i in range(8):     # palm-muted eighths, the chord opening up on beat 3
                if i in (4, 5):
                    for p in (low + 12, low + 19, low + 24): rhy.note(s + i * .5, .45, p, 78)
                else:
                    rhy.note(s + i * .5, .18, low + 12, 70 if i % 2 == 0 else 52)
            for i in range(8): bass.note(s + i * .5, .42, low, 80 if i % 2 == 0 else 64)
            for p in vce(pcs, 59, 71)[:3]: org.note(s, 4, p, 46)
            kick(dr, s, 104); kick(dr, s + 2.5, 86); snare(dr, s + 2, 100)   # half time
            for i in range(8): hat(dr, s + i * .5, 62 if i % 2 == 0 else 44)
            if b % 8 == 7: tom_run(dr, s + 2, 8, .25, 70)
            if b % 8 == 0: crash(dr, s, 92)
        return [rhy, bass, org, dr]

    def combat():
        lead = T(0, 29, "lead gtr"); harm = T(1, 29, "harmony gtr"); pw = T(2, 30, "power chords")
        org = T(3, 17, "perc organ"); dr = T(9, 0, "kit"); dr.kit(16)
        lead.cc(0, 1, 0); harm.cc(0, 1, 0)
        for b in range(bars):
            scale = scale_for(b, 48, 96)
            s = b * bar; r, pcs = chord(prog[b])
            low = 35 + (r - 35) % 12 + 12
            for off, d in ((0, 1.4), (1.5, .4), (2, 1.4), (3.5, .4)):
                for p in (low, low + 7, low + 12): pw.note(s + off, d, p, 84)
            for p in vce(pcs, 62, 74)[:3]:
                for off in (.5, 1, 2.5, 3): org.note(s + off, .3, p, 52)
            for off, d, p, bend in line[b]:
                at = s + off
                if bend:
                    # pick a whole step below and bend up into the note, then shake it
                    lead.bend(at - .01, -8191)
                    lead.note(at, d * .97, p, 104)
                    for k in range(1, 5): lead.bend(at + k * .06, -8191 + k * 8191 / 4)
                    lead.vib(at + .4, max(.2, d - .5), 1100, 6, bpm)
                else:
                    lead.note(at, d * .97, p, 96 if d >= .5 else 84)
                    if d >= 1: lead.vib(at + .25, d - .35, 700, 5.5, bpm)
                # second guitar a diatonic third under the climax and the last A section
                if 16 <= b < 32 or b >= 44:
                    idx = min(range(len(scale)), key=lambda k: abs(scale[k] - p))
                    harm.note(at, d * .97, scale[max(0, idx - 2)], 82)
            kick(dr, s, 112); kick(dr, s + .75, 86); kick(dr, s + 2, 104); kick(dr, s + 2.5, 86)
            for off in (1, 3): snare(dr, s + off, 112)
            for i in range(8): dr.note(s + i * .5, .2, 51, 80 if i % 2 == 0 else 60)
            if b % 4 == 3: tom_run(dr, s + 3, 4, .25, 92)
            if b % 4 == 0: crash(dr, s, 108)
        return [lead, harm, pw, org, dr]

    return "q", bpm, bar, bars, ambient, tension, combat


# ------------------------------------------------------------------------------ Glass Mountain
def suite_r():
    """7/8 throughout (grouped 2+2+3 eighths), E lydian: F#/E is the signature colour."""
    bpm, bar, bars = 168, 3.5, 64
    prog = ["E", "F#/E", "E", "F#/E", "C#m", "A", "B", "Bsus",
            "A", "E/G#", "F#m", "B", "C#m", "G#m", "A", "B",
            "E", "F#/E", "E", "F#/E", "D", "A", "E", "E",
            "C#m", "B/D#", "E", "F#", "A", "B", "Bsus", "B"]
    prog = prog + ["C#m", "A", "E", "B", "C#m", "A", "B", "Bsus",
                   "A", "E/G#", "F#m", "B", "C#m", "G#m", "A", "B",
                   "E", "F#/E", "E", "F#/E", "D", "A", "E", "E",
                   "C#m", "B/D#", "E", "F#", "A", "B", "Bsus", "B"]
    GROUP = [0, 1, 2]                # beat offsets of the 2+2+3 pulse (in quarter beats: 0, 1, 2)
    # the theme: a rising line that leans on the raised 4th (A#), sung by the choir / synth
    theme = [[(0, 1, 71), (1, 1, 73), (2, 1.5, 70)], [(0, 1, 68), (1, 1, 70), (2, 1.5, 73)],
             [(0, 2, 75), (2, 1.5, 71)], [(0, 1, 70), (1, 1, 68), (2, 1.5, 66)],
             [(0, 1, 68), (1, 1, 71), (2, 1.5, 73)], [(0, 2, 76), (2, 1.5, 73)],
             [(0, 1, 71), (1, 1, 73), (2, 1.5, 75)], [(0, 3.5, 76)]]
    theme_b = [[(0, 2, 73), (2, 1.5, 76)], [(0, 1, 75), (1, 1, 71), (2, 1.5, 68)],
               [(0, 2, 69), (2, 1.5, 73)], [(0, 1, 75), (1, 1, 78), (2, 1.5, 75)],
               [(0, 2, 76), (2, 1.5, 73)], [(0, 1, 71), (1, 1, 68), (2, 1.5, 71)],
               [(0, 2, 69), (2, 1.5, 73)], [(0, 3.5, 71)]]

    climax = [[(0, 2, 80), (2, 1.5, 76)], [(0, 1, 78), (1, 1, 75), (2, 1.5, 71)],
              [(0, 2, 76), (2, 1.5, 80)], [(0, 1, 82), (1, 1, 78), (2, 1.5, 73)],
              [(0, 2, 81), (2, 1.5, 76)], [(0, 1, 78), (1, 1, 75), (2, 1.5, 83)],
              [(0, 3.5, 76)], [(0, 1, 75), (1, 1, 78), (2, 1.5, 71)]]
    LYD = (4, 6, 8, 10, 11, 1, 3)

    def mel(b):
        if 32 <= b < 40: return []          # the quiet bridge: the band vamps, nobody sings
        b = b % 32
        sec = b // 8
        m = theme if sec in (0, 2) else theme_b
        notes = m[b % 8]
        if sec == 2 and b in (20, 21):   # the D and A bars: bend the theme to fit
            notes = [(0, 1, 74), (1, 1, 76), (2, 1.5, 78)] if b == 20 else [(0, 2, 76), (2, 1.5, 73)]
        if sec == 3:   # the climax gets its own line, written over its own chords
            notes = climax[b - 24]
        return notes

    def ambient():
        g12 = T(0, 25, "12-string"); choir = T(1, 52, "choir"); org = T(2, 16, "organ")
        bass = T(3, 34, "picked bass"); g12.cc(0, 93, 70)
        for b in range(bars):
            s = b * bar; bs, pcs = chord(prog[b])
            ext = pcs + [(pcs[0] + 2) % 12]
            arp = vce(ext, 59, 83)
            # eighth-note arpeggio across the 7, with a ringing top note on the long group
            pat = [0, 2, 1, 3, 2, 4, 5]
            for i in range(7): g12.note(s + i * .5, 1.4, arp[pat[i] % len(arp)], 48 if i in (0, 2, 4) else 36)
            for p in vce(pcs, 55, 67)[:3]: org.note(s, 3.5, p, 34)
            low = 40 + (bs - 40) % 12
            bass.note(s, 2, low, 46); bass.note(s + 2, 1.5, low + 7 if (bs + 7) % 12 in pcs else low + 12, 38)
            if b % 8 in (2, 3, 4, 5) and (b // 8) % 4 in (0, 2):
                for o, d, p in mel(b): choir.note(s + o, d, p, 40)
        return [g12, choir, org, bass]

    def tension():
        bass = T(0, 34, "picked bass"); org = T(1, 17, "perc organ"); g12 = T(2, 25, "12-string")
        dr = T(9, 0, "kit"); dr.kit(8)
        for b in range(bars):
            s = b * bar; bs, pcs = chord(prog[b])
            low = 40 + (bs - 40) % 12
            r = pcs[0]
            # busy, melodic bass in 7: root, octave, fifth, a passing note, octave, fifth, ninth
            fig = [0, 12, 7, 10 if (bs + 10) % 12 in LYD else 11, 12, 7, 14]
            for i, iv in enumerate(fig):
                bass.note(s + i * .5, .42, low + iv, 88 if i in (0, 2, 4) else 70)
            for off in GROUP:
                for p in vce(pcs, 60, 72)[:3]: org.note(s + off, .35, p, 58)
            if b % 2 == 0:
                for i, p in enumerate(vce(pcs, 64, 79)[:4]): g12.note(s + 2 + i * .25, 1.2, p, 40)
            # 2+2+3 on the ride, snare on the 3-group, kick under each group
            for i in range(7): dr.note(s + i * .5, .2, 51, 70 if i in (0, 2, 4) else 48)
            kick(dr, s, 100); kick(dr, s + 1, 82); snare(dr, s + 2, 96); kick(dr, s + 3, 70)
            if b % 8 == 7: tom_run(dr, s + 1.5, 8, .25, 72)
            if b % 8 == 0: crash(dr, s, 90)
        return [bass, org, g12, dr]

    def combat():
        moog = T(0, 81, "synth lead"); church = T(1, 19, "church organ"); choir = T(2, 52, "choir")
        strs = T(3, 49, "mellotron strings"); gtr = T(4, 29, "lead gtr"); dr = T(9, 0, "kit"); dr.kit(16)
        for b in range(bars):
            s = b * bar; bs, pcs = chord(prog[b])
            for o, d, p in mel(b):
                moog.note(s + o, d * .95, p + 12 if b >= 16 else p, 100)
                choir.note(s + o, d, p, 74)
            for p in vce(pcs, 52, 72)[:4]: church.note(s, 3.5, p, 70)
            for p in vce(pcs, 64, 79)[:3]: strs.note(s, 3.5, p, 64)
            # a guitar answering the theme in the gaps: fast descending figure in the 3-group
            if b % 2 == 1:
                sc = vce(pcs + [(pcs[0] + 2) % 12], 64, 90)
                idx = sc.index(min(sc, key=lambda p: abs(p - 83)))
                for k in range(6): gtr.note(s + 2 + k * .25, .25, sc[max(0, idx - k)], 88)
            # full kit in 7, crashes on the 3-group every fourth bar, a big unison fill at the ends
            kick(dr, s, 112); kick(dr, s + 1, 96); snare(dr, s + 2, 112); kick(dr, s + 2.5, 92); snare(dr, s + 3, 84)
            for i in range(7): hat(dr, s + i * .5, 76 if i in (0, 2, 4) else 54)
            if b % 4 == 0: crash(dr, s, 110)
            if b % 8 == 7:
                for k in range(6): dr.note(s + 2 + k * .25, .25, TOMS[k], 96)
        return [moog, church, choir, strs, gtr, dr]

    return "r", bpm, bar, bars, ambient, tension, combat


def main():
    os.makedirs(C.OUT, exist_ok=True)
    td = tempfile.mkdtemp()
    makers = {"p": suite_p, "q": suite_q, "r": suite_r}
    want = sys.argv[1:] or list(makers)
    for k in want:
        tag, bpm, bar, bars, amb, ten, com = makers[k]()
        C.BPM = bpm
        beats = bar * bars
        loop = int(round(beats * 60 / bpm * SR))
        for name, fn, gain, peak, target in (("ambient", amb, 0.5, 0.55, 0.084), ("tension", ten, 0.5, 0.6, 0.087),
                                             ("combat", com, 0.45, 0.75, 0.127)):
            tracks = fn()
            mid = os.path.join(td, f"{name}_{tag}.mid"); wav = os.path.join(td, f"{name}_{tag}.wav")
            C.save(tracks, mid, passes=3, length_beats=beats)
            x = C.render(mid, wav, gain)
            seg = x[loop:2 * loop]
            seg = seg / max(1e-6, np.max(np.abs(seg))) * peak
            # match the orchestral suites' loudness: drums are peaky, so lift quiet stems through a
            # gentle tanh soft-limiter rather than letting them sit under the others
            def lim(g):   # tanh soft-limiter; g -> 0 is the identity, the peak stays put
                return seg if g <= 0 else np.tanh(g * seg / peak) * peak / np.tanh(g)
            def loud(y): return float(np.sqrt((y.mean(axis=1) ** 2).mean()))
            g = 0.0
            while loud(lim(g)) < target and g < 3:
                g += 0.05
            seg = lim(g)
            print(f"  {name}_{tag}: rms {loud(seg):.3f} (drive {g:.2f})")
            C.encode(seg, os.path.join(C.OUT, f"{name}_{tag}.ogg"), 2)
            print(f"{name}_{tag}", "%.1fs" % (len(seg) / SR))


if __name__ == "__main__":
    main()
