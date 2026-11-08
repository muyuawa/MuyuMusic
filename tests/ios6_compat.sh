#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp="$(mktemp -d -t muyu-ios6)"
trap 'rm -rf "$task_tmp"' EXIT
clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -framework Foundation \
  tests/ios6_encoding.m -o "$task_tmp/encoding"
"$task_tmp/encoding"
clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework CoreImage -framework CoreGraphics \
  tests/ios6_qrcode.m Sources/Core/MCQRCode.m Sources/Core/qrcodegen.c -o "$task_tmp/qr"
"$task_tmp/qr"
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -framework Foundation \
  tests/ios6_audio_source.m Sources/Playback/MCAudioSource.m Sources/Playback/MCAudioPolicy.m \
  Sources/Playback/MCPlaybackCore.c -o "$task_tmp/audio"
"$task_tmp/audio"
