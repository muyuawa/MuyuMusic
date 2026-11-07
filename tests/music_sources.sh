#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="$(mktemp -t muyu-music-sources)"
trap 'rm -f "$output"' EXIT
clang -fobjc-arc -fblocks -Wall -Wextra -Wno-incomplete-implementation -framework Foundation tests/music_sources.m Sources/Network/MCMusicSources.m Sources/Network/MCSourceAPI.m -o "$output"
"$output"
