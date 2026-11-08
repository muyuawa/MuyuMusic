#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/test-theme.sh
bash tests/now_playing.sh
bash tests/ios6_compat.sh
python3 tests/ios6_theos.py
for task_test in tests/network_run.sh tests/network_transport.sh tests/library.sh tests/playback.sh tests/audio_cache.sh tests/source_integration.sh tests/music_sources.sh tests/source_repository.sh tests/lx_runtime.sh tests/source_runtime.sh; do
  bash "$task_test"
done
if [[ "${1:-}" == "--tls" ]]; then bash tests/network_bundled_tls.sh; fi
if [[ "${1:-}" == "--live" ]]; then bash tests/network_live.sh; fi
