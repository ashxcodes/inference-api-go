#!/usr/bin/env bash
# Alias for sweep.sh (random Amman trips is the default since predict-varied.js).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sweep.sh" "$@"
