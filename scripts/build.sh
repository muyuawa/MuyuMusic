#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f .build/deps/lib/libcurl.a || "$(cat .build/deps/.target 2>/dev/null)" != armv7-apple-ios6.0 ]]; then
  bash scripts/build-deps.sh
fi
test -x .deps/bin/ldid || { echo 'Run python3 scripts/bootstrap.py first.'; exit 1; }
bash scripts/build-quickjs.sh
mkdir -p .build/obj .build/package/Payload/MuyuMusic.app dist .build/logs
task_app="$PWD/.build/package/Payload/MuyuMusic.app"
task_flags=(-Oz -g0 -fblocks -fno-common -fvisibility=hidden -fno-objc-arc-exceptions -Wall -Wextra -Werror=unguarded-availability -Werror=implicit-function-declaration -Wno-unused-parameter -Wno-deprecated-declarations -I.build/quickjs/include -I.build/deps/include -ISources/Core -ISources/Network -ISources/Library -ISources/Playback -ISources/UI)
task_objects=()
while IFS= read -r task_source; do
  task_obj=".build/obj/${task_source//\//_}.o"
  task_extra=()
  if [[ "$task_source" == *.m ]]; then task_extra=(-fobjc-arc); fi
  scripts/cc-ios "${task_flags[@]}" "${task_extra[@]}" -c "$task_source" -o "$task_obj"
  task_objects+=("$task_obj")
done < <(find Sources -type f \( -name '*.m' -o -name '*.c' \) | sort)
# New compiler-rt uses a weak OS-version helper absent from SDK 7.1. Permit
# only that weak reference; its runtime falls back to SystemVersion.plist.
scripts/cc-ios "${task_objects[@]}" -Wl,-U,__availability_version_check -Wl,-dead_strip -Wl,-no_compact_unwind -Wl,-map,.build/link.map -framework UIKit -framework Foundation -framework AVFoundation -framework AudioToolbox -framework MediaPlayer -framework CoreMedia -framework Security -framework CoreGraphics -framework ImageIO -framework QuartzCore -lsqlite3 -lz .build/quickjs/armv7/libquickjs.a .build/deps/lib/libFLAC.a .build/deps/lib/libcurl.a .build/deps/lib/libmbedtls.a .build/deps/lib/libmbedx509.a .build/deps/lib/libmbedcrypto.a -o "$task_app/MuyuMusic"
cp Resources/Info.plist "$task_app/Info.plist"
cp Resources/LXPrelude.js "$task_app/LXPrelude.js"
cp Resources/cacert.pem "$task_app/cacert.pem"
cp Resources/*.png "$task_app/"
mkdir -p "$task_app/Licenses"
cp vendor/licenses/* "$task_app/Licenses/"
printf 'APPL????' > "$task_app/PkgInfo"
# Keep SHA-1 as the primary CodeDirectory for iOS 6, and seal bundle resources.
# Current macOS requires SHA-256 alongside SHA-1 even for ad-hoc signing.
codesign --force --sign - --identifier com.muyu.cloudmusic --entitlements Resources/Entitlements.plist --digest-algorithm=sha1,sha256 --timestamp=none "$task_app"
codesign --verify --strict "$task_app"
python3 scripts/verify-package.py "$task_app"
python3 scripts/package-ipa.py
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
shasum -a 256 "dist/MuyuMusic-$task_version-ios6-armv7.ipa"
echo "IPA: dist/MuyuMusic-$task_version-ios6-armv7.ipa"
