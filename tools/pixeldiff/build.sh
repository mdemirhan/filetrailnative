#!/bin/bash
# Compiles tools/pixeldiff into build/pixeldiff/pixeldiff when the source is newer. Prints the binary's path.
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=build/pixeldiff/pixeldiff
source=tools/pixeldiff/main.swift
if [ ! -x "$binary" ] || [ "$source" -nt "$binary" ]; then
    mkdir -p build/pixeldiff build/logs
    if ! xcrun swiftc -O -swift-version 6 -o "$binary" "$source" >build/logs/pixeldiff.log 2>&1; then
        grep -E 'error' build/logs/pixeldiff.log | head -20 >&2
        echo "pixeldiff: build failed; full log in build/logs/pixeldiff.log" >&2
        exit 1
    fi
fi
echo "$binary"
