#!/usr/bin/env bash
# Regenerate sw/fake08.patch from edits made in the patched copy (sw/build/fake-08).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/a" "$TMP/b"
cp -r "$ROOT/third_party/fake-08/source" "$ROOT/third_party/fake-08/libs" "$TMP/a/"
cp -r "$ROOT/sw/build/fake-08/source" "$ROOT/sw/build/fake-08/libs" "$TMP/b/"
rm -rf "$TMP"/a/libs/z8lua/.git "$TMP"/b/libs/z8lua/.git
(cd "$TMP" && diff -ruN a b > "$ROOT/sw/fake08.patch" || true)
echo "wrote sw/fake08.patch ($(grep -c '^+++ ' "$ROOT/sw/fake08.patch") files)"
