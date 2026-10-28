#!/bin/sh
# Installs crosstalk: Crosstalk.app on the Mac, and the NVDA stand-in plus the
# UIA proxy into a CrossOver bottle.
#
#   ./install.sh <bottle dir>              install (run build.sh first)
#   ./install.sh --uninstall <bottle dir>  remove from that bottle
#
# <bottle dir> is the bottle's folder, e.g. ~/Library/Application Support/CrossOver/Bottles/MyBottle.
# Repeat for each bottle. Re-run after a CrossOver update, so the copy of Wine's
# own uiautomationcore.dll the proxy forwards to matches the new Wine.
set -e
cd "$(dirname "$0")"

CX=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver
SUPPORT="$HOME/Library/Application Support/Crosstalk"
LAUNCHER="$SUPPORT/launch-crosstalk"

uninstall=0
if [ "$1" = "--uninstall" ]; then uninstall=1; shift; fi
BOTTLE="${1:?usage: $0 [--uninstall] <bottle dir>}"
BOTTLE="${BOTTLE%/}"
[ -f "$BOTTLE/cxbottle.conf" ] || { echo "$BOTTLE is not a CrossOver bottle"; exit 1; }

C="$BOTTLE/drive_c"
DEST="$C/Program Files/Crosstalk"

bottle() {
	CX_BOTTLE_PATH="$(dirname "$BOTTLE")" "$CX/bin/wine" --bottle "$(basename "$BOTTLE")" --wait-children -- "$@" 2>&1 \
		| grep -v -e ':fixme:' -e '^$' || true
}

# Our proxy names the DLL it forwards to; Wine's own copy does not.
is_proxy() { [ -f "$1" ] && grep -q crosstalk_wineuia "$1"; }

if [ $uninstall = 1 ]; then
	bottle 'C:\Program Files\Crosstalk\nvda.exe' --quit
	bottle reg delete 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' /v Crosstalk /f
	bottle reg delete 'HKCU\Software\Wine\DllOverrides' /v uiautomationcore /f
	bottle reg delete 'HKLM\Software\Crosstalk' /f
	for d in system32 syswow64; do
		if [ -f "$DEST/backup/$d/uiautomationcore.dll" ]; then
			cp "$DEST/backup/$d/uiautomationcore.dll" "$C/windows/$d/uiautomationcore.dll"
		fi
		rm -f "$C/windows/$d/crosstalk_wineuia.dll"
	done
	rm -rf "$DEST"
	echo "Removed crosstalk from $BOTTLE. Crosstalk.app itself is left installed."
	exit 0
fi

[ -x build/x64/nvda.exe ] || { echo "run ./build.sh first"; exit 1; }

echo "Mac: Crosstalk.app -> ~/Applications"
mkdir -p "$HOME/Applications" "$SUPPORT"
if pgrep -xq Crosstalk; then osascript -e 'quit app "Crosstalk"'; sleep 1; fi
rm -rf "$HOME/Applications/Crosstalk.app"
cp -R build/Crosstalk.app "$HOME/Applications/"
cat > "$LAUNCHER" <<EOF
#!/bin/sh
# Run from inside a Wine bottle by crosstalk's nvda.exe when Crosstalk is not
# running. Wine's start.exe /unix passes no arguments, hence this script.
exec /usr/bin/open -g -a "$HOME/Applications/Crosstalk.app" --args --background
EOF
chmod +x "$LAUNCHER"

echo "Bottle: $BOTTLE"
# Stop a running stand-in so its files can be replaced.
if [ -f "$DEST/nvda.exe" ]; then bottle 'C:\Program Files\Crosstalk\nvda.exe' --quit; sleep 1; fi
mkdir -p "$DEST"
cp build/x64/nvda.exe "$DEST/"

# The proxy goes where Wine's uiautomationcore.dll was, which is kept as a
# backup; Wine's implementation, which the proxy forwards to, sits beside it.
for pair in "system32 x86_64 x64" "syswow64 i386 x86"; do
	set -- $pair
	[ -d "$C/windows/$1" ] || continue
	mkdir -p "$DEST/backup/$1"
	if ! is_proxy "$C/windows/$1/uiautomationcore.dll" && [ -f "$C/windows/$1/uiautomationcore.dll" ]; then
		cp "$C/windows/$1/uiautomationcore.dll" "$DEST/backup/$1/"
	fi
	cp "$CX/lib/wine/$2-windows/uiautomationcore.dll" "$C/windows/$1/crosstalk_wineuia.dll"
	cp "build/$3/uiautomationcore.dll" "$C/windows/$1/uiautomationcore.dll"
done

bottle reg add 'HKCU\Software\Wine\DllOverrides' /v uiautomationcore /d native,builtin /f
bottle reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' /v Crosstalk \
	/d '"C:\Program Files\Crosstalk\nvda.exe"' /f
bottle reg add 'HKLM\Software\Crosstalk' /v Launcher /d "$LAUNCHER" /f

echo "Starting Crosstalk"
open "$HOME/Applications/Crosstalk.app"
# Run the stand-in now too; from here on the bottle starts it itself.
CX_BOTTLE_PATH="$(dirname "$BOTTLE")" "$CX/bin/wine" --bottle "$(basename "$BOTTLE")" \
	--cx-app 'C:\Program Files\Crosstalk\nvda.exe' >/dev/null 2>&1 &
echo "Done. Real NVDA must not run in this bottle at the same time."
