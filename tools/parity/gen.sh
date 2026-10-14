#!/usr/bin/env bash
# Regenerates the golden files in Tests/Golden from the reference app.
# Usage: tools/parity/gen.sh [--check] [suite...]   (no suite: every tools/parity/golden/*.ts)
# --check regenerates into a temp dir and fails, with a short diff, if any committed golden would change.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

check=0
suites=()
for arg in "$@"; do
  case "$arg" in
    --check) check=1 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    -*) echo "unknown option $arg" >&2; exit 2 ;;
    *) suites+=("$arg") ;;
  esac
done
if ((${#suites[@]} == 0)); then
  for file in tools/parity/golden/*.ts; do
    suites+=("$(basename "$file" .ts)")
  done
fi

if ((check == 0)); then
  bun tools/parity/lib/golden.ts --out Tests/Golden "${suites[@]}"
  echo "generated ${#suites[@]} suite(s): ${suites[*]}"
  exit 0
fi

# Machine-local suites (kind strings, folder sizes) differ per machine, so --check does not compare them.
checked=()
for suite in "${suites[@]}"; do
  if grep -qE '^export const machineLocal = true' "tools/parity/golden/$suite.ts" 2>/dev/null; then
    echo "skip $suite (machine-local)"
  else
    checked+=("$suite")
  fi
done
suites=(${checked[@]+"${checked[@]}"})
if ((${#suites[@]} == 0)); then echo "no checkable suites"; exit 0; fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bun tools/parity/lib/golden.ts --out "$tmp" "${suites[@]}"
changed=0
for suite in "${suites[@]}"; do
  if [[ ! -f "Tests/Golden/$suite.json" ]]; then
    echo "MISSING Tests/Golden/$suite.json (run tools/parity/gen.sh $suite)"
    changed=1
  elif ! cmp -s "Tests/Golden/$suite.json" "$tmp/$suite.json"; then
    echo "CHANGED Tests/Golden/$suite.json"
    diff -u "Tests/Golden/$suite.json" "$tmp/$suite.json" | sed -n '3,30p' | cut -c1-200 || true
    changed=1
  fi
done
if ((changed)); then
  echo "goldens drifted from the reference: review, then run tools/parity/gen.sh"
  exit 1
fi
echo "goldens up to date (${#suites[@]} suite(s))"
