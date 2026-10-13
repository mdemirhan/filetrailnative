#!/usr/bin/env bash
# Builds a tree with every kind of item, snapshots it with snapshot.ts (Bun) and with
# FTTestSupport.TreeSnapshot (Swift), and fails on any difference. Also snapshots the shared
# names fixture when it exists.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

tmp="$(mktemp -d)"
cleanup() {
  chflags -R nouchg,nohidden "$tmp" 2>/dev/null || true
  chmod -R -N "$tmp" 2>/dev/null || true
  chmod -R u+rwx "$tmp" 2>/dev/null || true
  rm -rf "$tmp" || true
}
trap cleanup EXIT

# The Swift snapshot tool, rebuilt when its sources change.
tool=build/parity/tree-snapshot
sources=(tools/parity/exec/snapshot-main.swift Tests/FTTestSupport/TreeSnapshot.swift Tests/FTTestSupport/JSONText.swift)
if [[ ! -x "$tool" ]] || [[ -n "$(find "${sources[@]}" -newer "$tool")" ]]; then
  mkdir -p build/parity
  xcrun swiftc -O -parse-as-library -swift-version 6 -o "$tool" "${sources[@]}"
fi

tree="$tmp/tree"
mkdir -p "$tree"/{nested/a/b/c,empty,sticky,readonly,Sample.app/Contents,"folder with acl"}
: >"$tree/empty.txt"
printf 'text\n' >"$tree/text.txt"
head -c 70000 /dev/urandom >"$tree/binary.bin"
printf '#!/bin/sh\n' >"$tree/exec.sh" && chmod 0755 "$tree/exec.sh"
printf 'private' >"$tree/private.txt" && chmod 0600 "$tree/private.txt"
printf 'setuid' >"$tree/setuid" && chmod 4755 "$tree/setuid"
printf 'read only' >"$tree/readonly.txt" && chmod 0444 "$tree/readonly.txt"
printf 'deep' >"$tree/nested/a/b/c/deep.txt"
printf '<plist/>' >"$tree/Sample.app/Contents/Info.plist"
printf 'in a read-only folder' >"$tree/readonly/inside.txt"
chmod 1777 "$tree/sticky"
printf 'nfc' >"$tree/$(printf 'Caf\xc3\xa9.txt')"
printf 'nfd' >"$tree/$(printf 'Cafe\xcc\x81 2.txt')"
printf 'emoji' >"$tree/🎉 party 👩‍👩‍👧‍👦.txt"
printf 'dot' >"$tree/.hidden-by-dot"
printf 'odd' >"$tree/$(printf 'line\nbreak "quoted" back\\slash\ttab.txt')"
printf 'hidden' >"$tree/hidden flag.txt" && chflags hidden "$tree/hidden flag.txt"
printf 'acl' >"$tree/acl.txt" && chmod +a "everyone deny delete" "$tree/acl.txt"
chmod +a "everyone deny add_file" "$tree/folder with acl"
ln "$tree/text.txt" "$tree/hard link.txt"
ln -s text.txt "$tree/link to file"
ln -s nested "$tree/link to folder"
ln -s does-not-exist "$tree/broken link"
ln -s /usr/bin "$tree/absolute link"
ln -s "$(printf 'Cafe\xcc\x81 2.txt')" "$tree/link to nfd"
mkfifo "$tree/pipe"
chmod 0555 "$tree/readonly"
printf 'locked' >"$tree/locked.txt" && chflags uchg "$tree/locked.txt"
mkdir "$tree/locked folder" && chflags uchg "$tree/locked folder"

failed=0
compare() {
  local label="$1" root="$2"
  bun tools/parity/exec/snapshot.ts "$root" "$tmp/$label-bun.json"
  "$tool" "$root" >"$tmp/$label-swift.json"
  if cmp -s "$tmp/$label-bun.json" "$tmp/$label-swift.json"; then
    echo "PASS $label ($(grep -c '"path"' "$tmp/$label-bun.json") items)"
  else
    echo "FAIL $label: snapshot.ts and TreeSnapshot differ"
    diff -u "$tmp/$label-bun.json" "$tmp/$label-swift.json" | sed -n '3,40p' | cut -c1-200 || true
    failed=1
  fi
}

compare tree "$tree"
# The built tree must show every kind and attribute, or the comparison proves little.
for needle in '"kind": "symlink"' '"kind": "other"' '"kind": "dir"' '"acl": true' '"uchg"' '"hidden"' '"mode": "4755"' '"mode": "1777"' '"target": "does-not-exist"'; do
  if ! grep -q "$needle" "$tmp/tree-bun.json"; then
    echo "FAIL tree: no item with $needle"
    failed=1
  fi
done

names="${FILETRAIL_PORT_CACHE:-$HOME/Library/Caches/filetrail-port}/fixtures/names"
if [[ -d "$names" ]]; then
  compare names "$names"
fi

# Normalization: recorded cases run again through the reference (run.ts --raw), then normalized by
# normalize.ts and by FTTestSupport.ExecNormalize, which must agree. The cases have hidden names
# left by a crash, recovery, journal ids, questions, file ids, and a disk image.
normalizer=build/parity/exec-normalize
normalizer_sources=(tools/parity/exec/normalize-main.swift Tests/FTTestSupport/ExecJSON.swift
  Tests/FTTestSupport/ExecNormalize.swift Tests/FTTestSupport/JSONText.swift)
if [[ ! -x "$normalizer" ]] || [[ -n "$(find "${normalizer_sources[@]}" -newer "$normalizer")" ]]; then
  mkdir -p build/parity
  xcrun swiftc -O -parse-as-library -swift-version 6 -o "$normalizer" "${normalizer_sources[@]}"
fi
for pick in exec-crash:1 exec-crash:3 exec-crash:13 exec-runtime:0 exec-runtime:5 exec-copy:16 exec-copy:19 exec-cut:11; do
  suite="${pick%%:*}" index="${pick##*:}" label="normalize-$suite-$index"
  bun tools/parity/exec/run.ts --raw --golden "$suite" "$index" >"$tmp/$label-raw.json"
  bun tools/parity/exec/normalize.ts "$tmp/$label-raw.json" >"$tmp/$label-bun.json"
  if out="$("$normalizer" "$tmp/$label-raw.json" "$tmp/$label-bun.json")"; then
    echo "PASS $label"
  else
    echo "FAIL $label: normalize.ts and ExecNormalize differ"
    echo "$out" | head -20 | cut -c1-200
    failed=1
  fi
done
exit "$failed"
