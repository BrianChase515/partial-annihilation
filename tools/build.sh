#!/bin/sh
# Build PartialAnnihilation.love from the repo root.
cd "$(dirname "$0")/.." || exit 1
rm -f PartialAnnihilation.love
zip -9 -r -q PartialAnnihilation.love main.lua conf.lua src assets
echo "Built PartialAnnihilation.love - run with: open -n -a love PartialAnnihilation.love"
