#!/bin/sh
# Build PartialAnnihilation.love from the repo root (and refresh dist/ for the in-game updater).
cd "$(dirname "$0")/.." || exit 1
if [ "$(cat VERSION)" != "$(sed -n 's/^D.VERSION = "\([^"]*\)".*/\1/p' src/defs.lua)" ]; then
  echo "VERSION and src/defs.lua D.VERSION differ - bump both"; exit 1
fi
rm -f PartialAnnihilation.love
zip -9 -r -q PartialAnnihilation.love main.lua conf.lua src assets
mkdir -p dist && cp PartialAnnihilation.love dist/PartialAnnihilation.love
echo "Built PartialAnnihilation.love v$(cat VERSION) - run with: open -n -a love PartialAnnihilation.love"
