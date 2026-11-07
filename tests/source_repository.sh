#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_output="$(mktemp -t muyu-source-repository)"
trap 'rm -f "$task_output"' EXIT
clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter -Wno-incomplete-implementation -Wno-deprecated-declarations -ISources/Network -framework Foundation tests/source_repository.m Sources/Network/MCMusicSources.m Sources/Network/MCSourceAPI.m Sources/Network/MCSourceRepository.m -o "$task_output"
"$task_output"
