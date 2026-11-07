#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="$(mktemp -t muyu-library)"
trap 'rm -f "$output"' EXIT
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -framework Foundation -framework AVFoundation -framework CoreMedia -framework ImageIO -framework CoreGraphics -lsqlite3 tests/library_tests.m Sources/Library/*.m -o "$output"
"$output"
