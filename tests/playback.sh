#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
playback_tmp=$(mktemp -d "${TMPDIR:-/tmp}/muyu-playback-tests.XXXXXX")
trap 'rm -rf "$playback_tmp"' EXIT HUP INT TERM
playback_sanitizers=
if [ "${PLAYBACK_SANITIZE:-0}" = 1 ]; then
    playback_sanitizers='-fsanitize=address,undefined -fno-omit-frame-pointer'
fi
# The C core is the production spool/range/PCM/queue implementation. UIKit,
# AVAssetResourceLoader and AudioQueue are cross-compiled by scripts/build.sh.
${CC:-cc} -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror -pthread \
    $playback_sanitizers tests/playback_core.c Sources/Playback/MCPlaybackCore.c \
    -o "$playback_tmp/playback"
"$playback_tmp/playback"
