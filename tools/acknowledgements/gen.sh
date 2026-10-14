#!/usr/bin/env bash
# Regenerates Resources/Acknowledgements (the open-source software the app ships and its license texts).
# Usage: tools/acknowledgements/gen.sh [--check]   (--check fails when the files are out of date and changes nothing)
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
exec bun tools/acknowledgements/gen.ts "$@"
