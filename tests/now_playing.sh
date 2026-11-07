#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/tests
clang -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined \
    tests/now_playing_layout.c Sources/Core/MCNowPlayingLayout.c -lm -o .build/tests/now-playing
.build/tests/now-playing
