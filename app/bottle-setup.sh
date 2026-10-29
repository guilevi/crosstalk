#!/bin/sh
# Sets crosstalk up in one CrossOver bottle, or takes it out again. Run by
# Crosstalk.app (Bottles, in Settings) and by install.sh.
#
#   bottle-setup.sh install <bottle dir>
#   bottle-setup.sh uninstall <bottle dir>
#
# The Windows files come from windows/ beside this script. $CX is the
# CrossOver to use (its Contents/SharedSupport/CrossOver), /Applications's by
# default. Installing again updates the files, which is needed after a
# CrossOver update so the copy of Wine's own uiautomationcore.dll the proxy
# forwards to matches the new Wine.
set -e

FILES="$(cd "$(dirname "$0")" && pwd)/windows"
CX="${CX:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}"
# Written by Crosstalk.app when it starts; nvda.exe runs it to open the app.
LAUNCHER="$HOME/Library/Application Support/Crosstalk/launch-crosstalk"

action="$1"
BOTTLE="${2:?usage: $0 install|uninstall <bottle dir>}"
BOTTLE="${BOTTLE%/}"
[ -f "$BOTTLE/cxbottle.conf" ] || { echo "$BOTTLE is not a CrossOver bottle."; exit 1; }
[ -x "$CX/bin/wine" ] || { echo "CrossOver was not found."; exit 1; }

C="$BOTTLE/drive_c"
DEST="$C/Program Files/Crosstalk"
# CrossOver lists Start Menu shortcuts as the bottle's launchers.
LINK='C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Crosstalk.lnk'

# Wine's output goes through a file, not a pipe: a wineserver the command
# boots keeps whatever it was given open, so a pipe would never close.
LOG="$(mktemp -t crosstalk)"
trap 'rm -f "$LOG"' EXIT
bottle() {
	CX_BOTTLE_PATH="$(dirname "$BOTTLE")" "$CX/bin/wine" --bottle "$(basename "$BOTTLE")" --wait-children -- "$@" >"$LOG" 2>&1 || true
	grep -v -e ':fixme:' -e '^$' "$LOG" || true
}

# Our proxy names the DLL it forwards to; Wine's own copy does not.
is_proxy() { [ -f "$1" ] && grep -q crosstalk_wineuia "$1"; }

case "$action" in
uninstall)
	bottle 'C:\Program Files\Crosstalk\nvda.exe' --quit
	bottle reg delete 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' /v Crosstalk /f
	bottle reg delete 'HKCU\Software\Wine\DllOverrides' /v uiautomationcore /f
	bottle reg delete 'HKLM\Software\Crosstalk' /f
	bottle cscript //nologo 'C:\Program Files\Crosstalk\shortcut.js' "$LINK" -
	for d in system32 syswow64; do
		if [ -f "$DEST/backup/$d/uiautomationcore.dll" ]; then
			cp "$DEST/backup/$d/uiautomationcore.dll" "$C/windows/$d/uiautomationcore.dll"
		fi
		rm -f "$C/windows/$d/crosstalk_wineuia.dll"
	done
	rm -rf "$DEST"
	echo "Removed crosstalk from $(basename "$BOTTLE")."
	;;
install)
	# Stop a running stand-in so its files can be replaced.
	if [ -f "$DEST/nvda.exe" ]; then bottle 'C:\Program Files\Crosstalk\nvda.exe' --quit; sleep 1; fi
	mkdir -p "$DEST"
	cp "$FILES/x64/nvda.exe" "$FILES/shortcut.js" "$DEST/"

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
		cp "$FILES/$3/uiautomationcore.dll" "$C/windows/$1/uiautomationcore.dll"
	done

	bottle reg add 'HKCU\Software\Wine\DllOverrides' /v uiautomationcore /d native,builtin /f
	bottle reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' /v Crosstalk \
		/d '"C:\Program Files\Crosstalk\nvda.exe"' /f
	bottle reg add 'HKLM\Software\Crosstalk' /v Launcher /d "$LAUNCHER" /f
	bottle cscript //nologo 'C:\Program Files\Crosstalk\shortcut.js' "$LINK" \
		'C:\Program Files\Crosstalk\nvda.exe' 'Start speech through Crosstalk'

	# Run the stand-in now too; from here on the bottle starts it itself.
	CX_BOTTLE_PATH="$(dirname "$BOTTLE")" "$CX/bin/wine" --bottle "$(basename "$BOTTLE")" \
		--cx-app 'C:\Program Files\Crosstalk\nvda.exe' >/dev/null 2>&1 &
	echo "Crosstalk is on in $(basename "$BOTTLE"). Real NVDA must not run there at the same time."
	;;
*)
	echo "usage: $0 install|uninstall <bottle dir>"; exit 1
	;;
esac
