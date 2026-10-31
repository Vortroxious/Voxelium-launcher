#!/usr/bin/env bash
# Fetches the licence files of idevice (MIT) and of every Rust crate listed in
# scripts/idevice-crates.txt into build/deps/idevice-licenses/, for
# scripts/collect-licenses.sh. Each crate is checked against its Cargo.lock checksum.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIST="$ROOT/scripts/idevice-crates.txt"
CACHE="$ROOT/build/deps/idevice-crates"
OUT="$ROOT/build/deps/idevice-licenses"
IDEVICE_TAG="v0.1.68"
mkdir -p "$CACHE" "$OUT"

curl -fsSL "https://raw.githubusercontent.com/jkcoxson/idevice/$IDEVICE_TAG/LICENSE.txt" -o "$OUT/idevice-LICENSE.txt"

missing=()
while read -r name version sum; do
  case "$name" in ''|'#'*) continue ;; esac
  crate="$CACHE/$name-$version.crate"
  if [ ! -f "$crate" ] || [ "$(shasum -a 256 "$crate" | cut -d' ' -f1)" != "$sum" ]; then
    curl -fsSL "https://static.crates.io/crates/$name/$name-$version.crate" -o "$crate"
  fi
  [ "$(shasum -a 256 "$crate" | cut -d' ' -f1)" = "$sum" ] || { echo "checksum mismatch: $name $version" >&2; exit 1; }
  dest="$OUT/$name-$version"
  rm -rf "$dest"; mkdir -p "$dest"
  # Licence files at the top of the crate (LICENSE, LICENSE-MIT, COPYING, NOTICE, UNLICENSE, ...).
  tar -tzf "$crate" | grep -E "^$name-$version/(LICEN[CS]E|COPYING|NOTICE|UNLICENSE|COPYRIGHT)[^/]*$" > "$dest.files" || true
  if [ -s "$dest.files" ]; then
    tar -xzf "$crate" -C "$dest" --strip-components 1 $(cat "$dest.files")
  else
    missing+=("$name-$version")
  fi
  rm -f "$dest.files"
  # The licence the crate declares, for the notice heading.
  tar -xzOf "$crate" "$name-$version/Cargo.toml" | sed -n 's/^license = "\(.*\)"/\1/p' | head -1 > "$dest/.spdx"
done < "$LIST"

printf '%s\n' "${missing[@]:-}" | sed '/^$/d' > "$OUT/no-licence-file.txt"
echo "licences in $OUT ($(ls -d "$OUT"/*/ | wc -l | tr -d ' ') crates; without a licence file: $(wc -l < "$OUT/no-licence-file.txt" | tr -d ' '))"
