#!/bin/sh
# Builds every part of crosstalk into build/.
#   build/Crosstalk.app                    macOS speech server, menu-bar item and settings,
#                                          carrying the Windows parts for bottles
#   build/crosstalkd                       the same server, headless
#   build/x64/nvda.exe                     stand-in NVDA for the bottle
#   build/{x64,x86}/uiautomationcore.dll   UIA notification proxy
#   build/{x64,x86}/ct_test.exe            test client (see tests/)
# Requires Xcode command line tools and mingw-w64 (brew install mingw-w64).
set -e
cd "$(dirname "$0")"
mkdir -p build/x64 build/x86 build/gen

CFLAGS="-O2 -Wall -Wextra -Wno-missing-field-initializers -static -static-libgcc"

SWIFTFLAGS="-O -swift-version 5"
# Universal, for the macOS Info.plist names as the minimum.
MINOS=$(plutil -extract LSMinimumSystemVersion raw app/Info.plist)
swiftu() {
	out=$1; shift
	for a in arm64 x86_64; do
		swiftc $SWIFTFLAGS -target $a-apple-macos$MINOS -module-cache-path build/gen/mc -o "$out.$a" "$@"
	done
	lipo -create -output "$out" "$out.arm64" "$out.x86_64"
	rm -f "$out.arm64" "$out.x86_64"
}
# Sign with a stable identity when there is one, so the Accessibility grant
# survives rebuilds; ad hoc otherwise.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')

echo "crosstalkd"
swiftu build/crosstalkd daemon/Speaker.swift daemon/Server.swift daemon/BottleWatcher.swift daemon/main.swift

echo "nvda.exe"
(cd build/gen && x86_64-w64-mingw32-widl -m64 -h -s --prefix-server=nvdaController_ \
	-S nvdaController_s.c -H nvdaController.h ../../wine/nvda/nvdaController.idl)
x86_64-w64-mingw32-gcc $CFLAGS -municode -mwindows -Ibuild/gen -o build/x64/nvda.exe \
	wine/nvda/nvda.c build/gen/nvdaController_s.c wine/common/crosstalk_client.c \
	-lrpcrt4 -lws2_32

for arch in x64 x86; do
	if [ $arch = x64 ]; then cc=x86_64-w64-mingw32-gcc; else cc=i686-w64-mingw32-gcc; fi
	echo "uiautomationcore.dll ($arch)"
	$cc $CFLAGS -shared -Wl,--kill-at,--enable-stdcall-fixup -o build/$arch/uiautomationcore.dll \
		wine/uia/uia_proxy.c wine/uia/rpc_fixes.c wine/common/crosstalk_client.c wine/uia/uiautomationcore.def \
		-lws2_32 -lrpcrt4 -loleaut32 -lole32 -luuid
	echo "ct_test.exe ($arch)"
	$cc $CFLAGS -o build/$arch/ct_test.exe tests/ct_test.c -lrpcrt4 -lole32 -loleaut32 -luuid
done

echo "Crosstalk.app"
APP=build/Crosstalk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp app/Info.plist "$APP/Contents/"
swiftu "$APP/Contents/MacOS/Crosstalk" -parse-as-library \
	daemon/Speaker.swift daemon/Server.swift daemon/BottleWatcher.swift app/Bottles.swift app/App.swift
# What Settings installs into bottles.
RES="$APP/Contents/Resources"
mkdir -p "$RES/windows/x64" "$RES/windows/x86"
cp app/bottle-setup.sh "$RES/"
cp wine/shortcut/shortcut.js "$RES/windows/"
cp build/x64/nvda.exe build/x64/uiautomationcore.dll "$RES/windows/x64/"
cp build/x86/uiautomationcore.dll "$RES/windows/x86/"
codesign --force --sign "${IDENTITY:--}" "$APP" >/dev/null
