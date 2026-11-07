#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/quickjs
bash scripts/build-quickjs.sh --host > .build/quickjs/e2e-build.log 2>&1
clang -fobjc-arc -fblocks -Wall -Wextra -Wno-deprecated-declarations -Wno-unused-parameter -I.deps/src/mbedtls-3.6.7/include -I.build/deps/include -I.build/quickjs/include -ISources/Network -framework Foundation -framework Security -lcurl Sources/Network/MCEAPI.m Sources/Network/MCHTTPClient.m Sources/Network/MCAPI.m Sources/Network/MCSourceAPI.m Sources/Network/MCMusicSources.m Sources/Network/MCLXRuntime.m tests/source_runtime.m .build/quickjs/host/libquickjs.a .build/quickjs/mbedtls/library/libmbedcrypto.a -lz -o .build/quickjs/source-runtime-tests
.build/quickjs/source-runtime-tests
