#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_sdk="${IOS_SDK:-$PWD/.deps/sdk71/iPhoneOS7.1.sdk}"
while IFS= read -r task_source; do
  task_extra=()
  if [[ "$task_source" == *.m ]]; then task_extra=(-fobjc-arc); fi
  /usr/bin/clang -target armv7-apple-ios6.0 -isysroot "$task_sdk" -fsyntax-only -fblocks \
    "${task_extra[@]}" -Wall -Wextra -Werror=unguarded-availability -Werror=partial-availability \
    -Wno-unused-parameter -Wno-deprecated-declarations -I.build/quickjs/include -I.build/deps/include \
    -ISources/Core -ISources/Network -ISources/Library -ISources/Playback -ISources/UI "$task_source"
done < <(find Sources -type f \( -name '*.m' -o -name '*.c' \) | sort)
echo 'All sources pass ARMv7 / iOS 6.0 API availability checks.'
