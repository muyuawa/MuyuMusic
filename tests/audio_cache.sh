#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="$(mktemp -t muyu-audio-cache)"
trap 'rm -f "$output"' EXIT
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation tests/audio_cache.m Sources/Playback/MCAudioCache.m -o "$output"
"$output"
