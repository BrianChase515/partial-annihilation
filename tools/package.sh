#!/bin/sh
# Build standalone Windows (.zip with a single .exe) and Linux (.AppImage) versions.
# Needs: zip, curl, and the LÖVE 11.5 release files (downloaded on first run into tools/cache).
set -e
cd "$(dirname "$0")/.." || exit 1
sh tools/build.sh >/dev/null
V=$(cat VERSION)
CACHE=tools/cache
mkdir -p "$CACHE" dist
REL=https://github.com/love2d/love/releases/download/11.5
[ -f "$CACHE/love-11.5-win64.zip" ] || curl -fsSL -o "$CACHE/love-11.5-win64.zip" "$REL/love-11.5-win64.zip"
[ -f "$CACHE/love-11.5-x86_64.AppImage" ] || curl -fsSL -o "$CACHE/love-11.5-x86_64.AppImage" "$REL/love-11.5-x86_64.AppImage"
[ -f "$CACHE/appimagetool" ] || curl -fsSL -o "$CACHE/appimagetool" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$CACHE/love-11.5-x86_64.AppImage" "$CACHE/appimagetool"
WORK=$(mktemp -d)

# --- Windows: love.exe + game = PartialAnnihilation.exe, next to LÖVE's DLLs
(cd "$WORK" && unzip -q "$OLDPWD/$CACHE/love-11.5-win64.zip")
W="$WORK/love-11.5-win64"
cat "$W/love.exe" PartialAnnihilation.love > "$W/PartialAnnihilation.exe"
rm -f "$W/love.exe" "$W/lovec.exe" "$W/readme.txt" "$W/changes.txt"
mv "$W/license.txt" "$W/LOVE-license.txt"
cp LICENSE "$W/LICENSE.txt"
printf 'Partial Annihilation v%s\r\n\r\nDouble-click PartialAnnihilation.exe to play.\r\nWindows may warn that the app is from an unknown publisher: click "More info", then "Run anyway".\r\n' "$V" > "$W/README.txt"
rm -rf "$WORK/PartialAnnihilation"
mv "$W" "$WORK/PartialAnnihilation"
rm -f dist/PartialAnnihilation-windows.zip
(cd "$WORK" && zip -9 -q -r "$OLDPWD/dist/PartialAnnihilation-windows.zip" PartialAnnihilation)

# --- Linux / Steam Deck: fuse the game into LÖVE's AppImage
(cd "$WORK" && "$OLDPWD/$CACHE/love-11.5-x86_64.AppImage" --appimage-extract >/dev/null)
S="$WORK/squashfs-root"
cat "$S/bin/love" PartialAnnihilation.love > "$S/bin/love.fused"
mv "$S/bin/love.fused" "$S/bin/love"
chmod +x "$S/bin/love"
sed -i 's/^Name=.*/Name=Partial Annihilation/; s/^Comment=.*/Comment=A lightweight RTS with a roguelike Commander/' "$S"/*.desktop
rm -f dist/PartialAnnihilation-x86_64.AppImage
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$CACHE/appimagetool" --no-appstream "$S" dist/PartialAnnihilation-x86_64.AppImage >/dev/null 2>&1
chmod +x dist/PartialAnnihilation-x86_64.AppImage
rm -rf "$WORK"
ls -la dist/
