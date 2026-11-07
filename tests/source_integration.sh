#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="$(mktemp -t muyu-sources-integration)"
trap 'rm -f "$output"' EXIT
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -ISources/Playback -framework Foundation tests/source_integration.m Sources/Playback/MCAudioPolicy.m Sources/Playback/MCAudioCache.m -o "$output"
"$output"
