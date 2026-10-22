#!/usr/bin/env python3
"""Online leaderboard bot (run by .github/workflows/leaderboard.yml).

  leaderboard.py submit   - read the GitHub issue that triggered the run, validate the
                            pa-score block, add it to leaderboard/v<VERSION>.json
  leaderboard.py render   - rewrite LEADERBOARD.md for the current VERSION

Each game version gets its own board, so bumping VERSION starts a fresh season.
Writes the reply for the issue to /tmp/reply.md."""
import json, os, re, sys, datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FULL_VERSION = open(os.path.join(ROOT, "VERSION")).read().strip()
VERSION = ".".join(FULL_VERSION.split(".")[:2])   # the high-score season: patch releases share it
def board_path(mode="rts"):
    return os.path.join(ROOT, "leaderboard", ("arena-" if mode == "arena" else "") + f"v{VERSION}.json")
REPLY = "/tmp/reply.md"

def check32(s):
    h = 2166136261
    for b in s.encode():
        h ^= b
        h = (h * 16777619) % 4294967296
    return f"{h:08x}"

def load(mode="rts"):
    try:
        with open(board_path(mode)) as f: return json.load(f)
    except FileNotFoundError:
        return []

def save(board, mode="rts"):
    p = board_path(mode)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f: json.dump(board, f, indent=1)

def table(board):
    if not board:
        return ["_No scores yet this version._"]
    out = ["| # | Player | Score | Result | Time | Players | Opponents | Date |", "|---|---|---|---|---|---|---|---|"]
    for i, e in enumerate(board[:100], 1):
        out.append(f"| {i} | [{e['name']}](https://github.com/{e['name']}) | {e['score']:,} | {e['result']} | {e['time']} "
                   f"| {e['players']} | {e['lineup']} | {e['date']} |")
    return out

def render(_=None):
    lines = [f"# Partial Annihilation leaderboard - season {VERSION}", "",
             "Each season (0.9, 0.10, ...) starts a fresh board; patch releases keep it. Submit from the end-of-game screen (**Submit score online**).", "",
             "## RTS", "", "Official games only: no Alien Tech or Dropships.", ""]
    lines += table(load("rts"))
    lines += ["", "## Commander Arena", ""]
    lines += table(load("arena"))
    with open(os.path.join(ROOT, "LEADERBOARD.md"), "w") as f:
        f.write("\n".join(lines) + "\n")

def reply(text):
    with open(REPLY, "w") as f: f.write(text)

def submit():
    ev = json.load(open(os.environ["GITHUB_EVENT_PATH"]))
    issue = ev["issue"]
    m = re.search(r"```pa-score\s*\n(.*?)```", issue.get("body") or "", re.S)
    if not m:
        reply("I couldn't find a score block in this issue. Please submit from the game's end screen."); return 1
    fields = {}
    for line in m.group(1).splitlines():
        if ":" in line:
            k, v = line.split(":", 1); fields[k.strip()] = v.strip()
    try:
        score = int(fields["score"])
        key = "|".join([fields["version"], fields["score"], fields["result"], fields["time"], fields["map"]])
    except (KeyError, ValueError):
        reply("This score block is incomplete. Please submit from the game's end screen."); return 1
    if ".".join(fields["version"].split(".")[:2]) != VERSION:
        reply(f"This score is from v{fields['version']}, but the current board is v{VERSION}. "
              "Update the game from its title screen and play another round!"); return 1
    if check32(key + "|partial") != fields.get("check") or not (0 < score < 50_000_000):
        reply("This score didn't pass the check, so it wasn't added."); return 1
    name = issue["user"]["login"]
    mode = "arena" if fields.get("mode") == "arena" else "rts"
    entry = {"name": name, "score": score, "result": fields["result"], "time": fields["time"],
             "players": fields.get("players", "?"), "lineup": fields.get("lineup", "").replace("|", "/")[:80],
             "date": datetime.date.today().isoformat(), "issue": issue["number"]}
    board = load(mode)
    old = next((e for e in board if e["name"] == name), None)
    if old and old["score"] >= score:
        render()
        reply(f"Thanks {name}! Your best this version is still {old['score']:,}, so the board is unchanged."); return 0
    board = [e for e in board if e["name"] != name] + [entry]
    board.sort(key=lambda e: -e["score"])
    save(board, mode); render()
    rank = next(i for i, e in enumerate(board, 1) if e["name"] == name)
    reply(f"Added! **{score:,}** puts {name} at **#{rank}** on the v{VERSION} "
          f"[leaderboard](https://github.com/{os.environ.get('GITHUB_REPOSITORY', 'BrianChase515/partial-annihilation')}/blob/main/LEADERBOARD.md).")
    return 0

if __name__ == "__main__":
    if sys.argv[1:] == ["render"]:
        render(); sys.exit(0)
    sys.exit(submit())
