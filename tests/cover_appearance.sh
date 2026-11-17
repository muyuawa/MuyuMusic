#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/tests
clang -std=c99 -Wall -Wextra -Werror -ISources/Core -fsanitize=address,undefined \
    tests/cover_appearance.c Sources/Core/MCCoverAppearance.c Sources/Core/MCColor.c \
    Sources/Core/MCNowPlayingLayout.c -lm -o .build/tests/cover-appearance
.build/tests/cover-appearance
