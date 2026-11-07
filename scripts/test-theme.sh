#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
clang -std=c99 -Wall -Wextra -Werror -ISources/Core tests/theme.c Sources/Core/MCColor.c -lm -o .build/tests/theme
.build/tests/theme
clang -Wall -Wextra -Werror tests/time.c Sources/Core/MCTime.c -o .build/tests/time
.build/tests/time
