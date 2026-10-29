#!/bin/sh
# Installs crosstalk from a build: Crosstalk.app on the Mac, and the NVDA
# stand-in plus the UIA proxy into a CrossOver bottle. Crosstalk.app can do
# the bottle part itself (Settings, Bottles); this is the same from a terminal.
#
#   ./install.sh <bottle dir>              install (run build.sh first)
#   ./install.sh --uninstall <bottle dir>  remove from that bottle
#
# <bottle dir> is the bottle's folder, e.g. ~/Library/Application Support/CrossOver/Bottles/MyBottle.
# Repeat for each bottle. Re-run after a CrossOver update, so the copy of Wine's
# own uiautomationcore.dll the proxy forwards to matches the new Wine.
set -e
cd "$(dirname "$0")"

APP="$HOME/Applications/Crosstalk.app"
SETUP=Contents/Resources/bottle-setup.sh

if [ "$1" = "--uninstall" ]; then
	if [ -x "$APP/$SETUP" ]; then exec "$APP/$SETUP" uninstall "$2"; fi
	exec "build/Crosstalk.app/$SETUP" uninstall "$2"
fi

[ -x "build/Crosstalk.app/$SETUP" ] || { echo "run ./build.sh first"; exit 1; }

echo "Mac: Crosstalk.app -> ~/Applications"
mkdir -p "$HOME/Applications"
if pgrep -xq Crosstalk; then osascript -e 'quit app "Crosstalk"'; sleep 1; fi
rm -rf "$APP"
cp -R build/Crosstalk.app "$HOME/Applications/"
# Started first: it writes the launcher the bottle uses to open it.
open "$APP"

echo "Bottle: ${1:?usage: $0 [--uninstall] <bottle dir>}"
"$APP/$SETUP" install "$1"
