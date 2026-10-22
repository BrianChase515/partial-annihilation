# Partial Annihilation

**A lightweight real-time strategy game for the Mac, in the spirit of Total Annihilation, where the units are shapes and numbers.**

Land, sea and air. Up to 4 players with teams. Procedural maps. The whole game is about 80 KB of compressed Lua plus about 3 MB of music, and it runs on the tiny [LÖVE](https://love2d.org) engine, which runs natively on Apple Silicon. It was built to stay out of the way on a machine that's busy doing other things, like running a local AI model.

![A 2v2 battle: green's veteran tanks push into red's base](screenshots/battle-2v2.png)

## What makes it different

- **Your Commander is a super unit, and losing him loses the game.** He levels up only from **his own kills**. Each level from 1 to 4 offers a roguelike pick: **2 random upgrades out of a pool of 20**, and whatever you take never comes up again. The pool includes:
  - Second Wind, Emergency Recall, Repair Aura and Inspiring Presence
  - Explosive Shells, Flak Mount, Resource Siphon and Salvager
  - instant veteran Reinforcements, and more

  **Level 5 is always the Nuke.** Every player sees the launch warning, the slow missile and the target circle. It destroys every building in the blast (yours too, if you aim badly) and halves the health of every unit caught in it. Commanders are immune, and it recharges for 10 minutes. The more you send him into combat, the stronger he gets, and the more likely you are to lose the game.
- **Computer opponents that use their Commander well.** They level him by defending when the odds are good. They escort strong waves from the back once he has survivability upgrades. They retreat to their best-defended position when hurt or outgunned. They pick upgrades that suit their personality, and they aim nukes at the most valuable enemy targets while avoiding their own and their allies' buildings.
- **Separate difficulty and personality settings.** Difficulty runs from 1 to 10. There are eight personalities: *Balanced, Aggressive, Turtle, Boomer, Air, Naval, Raider* and *Warlord* (a battle-hungry Commander who leads from the front), plus *Random*. Each computer player gets its own pair.
- **Up to 4 players, any teams.** Free-for-all, 2v2, 1v3, or you plus a computer ally. You see whatever your allies see. When a player's Commander falls, their forces self-destruct.
- **Every game is scored, with an online leaderboard.** Kills are worth the metal value of what you destroy, and a kill-streak multiplier holds until 10 seconds pass without an enemy dying. Your points are then scaled by enemy difficulty, by the opposition (a 1v2 against a team is worth far more than a free-for-all where the computers also fight each other) and by your time against par. The end screen breaks every part of it down. Games without Alien Tech or Dropships are **official**: they go on your high-score table, and one click submits them to the [online leaderboard](LEADERBOARD.md). Each game version starts a fresh board.
- **Game modifiers you can combine:**
  - **Alien Tech:** a huge alien walker is announced, then lands near the middle of the map. Hold its zone for 15 seconds with no enemies inside to claim it, king-of-the-hill style. After each capture, another one lands somewhere else.
  - **Dropships:** from minute 3, neutral alien crews drop near the middle and wander. When one meets you, the game pauses for a moment while a coin flips: heads they join you, tails they attack.
  - **Groovy:** flower-power explosions, 60s/70s colors and a slowly shifting, color-cycling landscape.
- **Select Half.** `H` halves your selection while keeping the same mix of unit types, choosing the half nearest your mouse. `Shift+H` flips to the other half. The idea comes from AI War.
- **Retreat has a real cost.** `F` pulls units back at +25% speed, but their weapons stay offline until they're fully repaired. If the enemy chases, they're defenseless.
- **Drag-to-build, nearest first.** Drag a box to fill it with extractors on every deposit, or with buildings in a grid. Each constructor takes the closest jobs first.
- **Factory output joins control groups**, and **every unit has veterancy**, including towers.
- **Total Annihilation-style economy, and maps you can keep.** If you overspend, every project slows down by the same amount instead of the oldest one hogging everything. Maps are procedurally generated and symmetric, and you can save the ones you like by name.
- **A dynamic orchestral score and a robotic announcer.** Three tempo-locked orchestral layers loop in sync and crossfade with how much fighting you're in: strings, choir and harp when it's quiet; cellos, tremolo strings and timpani when enemies are in sight; full brass and percussion in a real battle. Victory and defeat get their own fanfare. A robot voice calls out base attacks, a Commander under fire, incoming nukes, dropships, alien tech, a stalled economy and more.
- **Every order is a button.** A bar above the bottom panel shows Attack, Stop, Patrol, Flee, Flag, Destroy, Select half and the rest, each with its shortcut and a tooltip, so you never have to learn the keys.
- **Maps built for all three domains.** Most maps are ringed by ocean with bays and rivers cut inland, and every body of water connects. A shipyard is never stranded in a lake.
- **Updates itself.** The title screen checks GitHub and offers a one-click update to the newest build.
- **Match logs.** Every game writes a readable log (minute-by-minute economy, armies, Commander levels, key events and the score) to a `logs` folder next to the game, which is handy for balance feedback.
- **Quality-of-life touches:**
  - a sidebar listing every factory and builder
  - a follow camera and a cinematic camera
  - right-drag panning
  - mouse lock so edge-panning works in a window
  - clickable game-speed controls

| | |
|---|---|
| ![Commander level-up: pick 1 of 2 random upgrades](screenshots/commander-upgrade.png) | ![The Nuke: everyone sees where it will land](screenshots/nuke.png) |
| ![Groovy modifier with a live Score-mode leaderboard](screenshots/groovy.png) | ![Base building](screenshots/base.png) |
| ![Title screen and lobby](screenshots/lobby.png) | ![A raid](screenshots/raid.png) |

## Units

Shapes tell you the domain, and the number tells you the type:

| Shape | Domain | Units |
|---|---|---|
| Square | Land | Constructor (B), Scout (1), Tank (2), Artillery (3), Flak Truck (4), Commander (CMD) |
| Triangle | Air | Fighter (1), Bomber (2), Gunship (3) |
| Circle | Sea | Patrol Boat (1), Destroyer (2), Submarine (3, only ships can hit it) |

**Buildings:**
- Metal Extractor
- Solar Collector
- Storage
- Vehicle Plant
- Aircraft Plant
- Shipyard
- Gun Tower
- AA Tower

## Playing on a Mac

1. Install **LÖVE 11.5** from [love2d.org](https://love2d.org) (the macOS download is a universal app). Move `love.app` into Applications.
2. Build the game file. Run `tools/build.sh`, or zip the contents of this folder (`main.lua`, `conf.lua`, `src/`, `assets/`) into `PartialAnnihilation.love`.
3. Run it with `open -n -a love PartialAnnihilation.love`, or drag the `.love` file onto `love.app`.

Or download the newest build directly: [`dist/PartialAnnihilation.love`](dist/PartialAnnihilation.love). After that, the game updates itself from its title screen.

The same `.love` file runs on Windows and Linux with LÖVE 11.5.

## Controls

| Action | Keys |
|---|---|
| Select / add | Left-click or drag; Shift adds; double-click selects all of a type on screen |
| Move / attack / assist | Right-click (Shift queues) |
| Attack-move, Stop, Patrol | `A` then click, `S`, `P` then click |
| Plant retreat flag | `Ctrl+F` at the mouse (or the Flag button, then click) |
| Self-destruct selection | `Delete` (unfinished buildings refund their metal; the Commander needs two presses) |
| Drop last queued order | `Shift+Delete` |
| Retreat to flag / Commander | `F` / `Shift+F`; plant the flag with `Ctrl+F` |
| Commander upgrade choice | `Z` / `X` (or click a card) |
| Nuke (Commander level 5) | `N`, then click the target |
| Select all combat units | `Ctrl+A` / `Cmd+A` |
| Select half / other half | `H` / `Shift+H` |
| Control groups | `Ctrl+1-9` save, `Shift+1-9` add, `1-9` recall (tap twice to jump there) |
| Build / produce | `Q W E R T Y U I` with a constructor or factory selected; drag for an area |
| Factory output to group | `Option+1-9` (`Option+0` clears) |
| Camera | Scroll to zoom; right- or middle-drag, arrow keys or screen edge to pan; `Option`+scroll pans |
| Follow / cinematic camera | `L` / `Shift+L` |
| Jump to Commander / last attack | `C` / `Space` |
| Idle constructor | `Tab` |
| Sidebar, speed, pause | `B`; `+`/`-`; `F3` (the top bar is clickable too) |
| Sound effects / music / announcer | `M` / `Shift+M` / `V` |
| Help | `F1` |

## How it's built

Plain Lua on LÖVE 11.5, with no other dependencies.

| File | What it does |
|---|---|
| `src/map.lua` | Procedural symmetric maps and connectivity |
| `src/path.lua` | A* pathfinding with smoothing and per-frame budgets |
| `src/world.lua` | The simulation: economy, construction, combat, veterancy, fog of war, retreat and repair |
| `src/ai.lua` | Computer opponents: economy, production, waves, raids, retreating, Commander tactics, nuke targeting, multi-enemy targeting |
| `src/commander.lua` | Commander levels, the 20-upgrade pool and the Nuke |
| `src/mods.lua` | Game modifiers: Alien Tech, Dropships, Score mode |
| `src/scores.lua`, `src/online.lua` | Local high scores; update check, one-click update and online leaderboard (via `curl` and GitHub) |
| `src/matchlog.lua` | Per-game logs for balance review |
| `tools/leaderboard.py`, `.github/workflows/leaderboard.yml` | The leaderboard bot: checks a submitted score issue, updates `LEADERBOARD.md`, then replies and closes the issue |
| `src/game.lua`, `src/ui.lua`, `src/render.lua` | Input, the HUD and drawing |
| `src/menu.lua`, `src/maps.lua` | Lobby and saved maps |
| `src/sfx.lua` | Procedurally generated sound effects |
| `src/music.lua`, `src/voice.lua` | Intensity-driven music crossfading and the announcer queue |
| `tools/compose.py`, `tools/voices.py` | Compose the score as MIDI and render it with FluidSynth (FluidR3 GM soundfont, MIT); render the announcer with espeak-ng plus a ring-modulator robot filter |

### Testing

Computer-vs-computer games run headless at high speed:

```sh
love . --autotest 25 <seed> <size> <level1> <profile1> <level2> <profile2> [--mods alien,drops,groovy]
love . --autotest4 30 <seed> 128 ffa|2v2|3
love . --smoketest     # a scripted "player" drives the real input handlers
```

### Releasing

Bump `VERSION` and `D.VERSION` in `src/defs.lua` together, then run `tools/build.sh` (it refreshes `dist/PartialAnnihilation.love`) and push. Players get the update from the title screen, and the leaderboard starts a new season for the new version.

## License

MIT. See [LICENSE](LICENSE).
