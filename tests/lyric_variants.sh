#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/tests
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation -ISources/Library \
    tests/lyric_variants.m Sources/Library/MCLyrics.m -o .build/tests/lyric-variants
.build/tests/lyric-variants
