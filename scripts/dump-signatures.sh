#!/usr/bin/env bash
# Dump BSim signatures from bsim_postgres into signatures/ as XML files.
# Each .o file is one BSim executable, identified by md5; multiple md5s share
# the same metadata name (e.g. "zlib@1.3.1-x86_64"). Dump per-md5 into a
# per-(name) directory so restore-signatures.sh can commit each group.
#
# Usage:
#   dump-signatures.sh                  # full dump (replaces signatures/)
#   dump-signatures.sh --only-non-o0    # incremental: dump only exes whose
#                                       # name ends in -O<level> (anything but
#                                       # the empty / -O0 suffix), and merge
#                                       # into existing signatures/.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT"

ONLY_NON_O0=0
if [ "${1:-}" = "--only-non-o0" ]; then
  ONLY_NON_O0=1
fi

BSIM_URL='postgresql://user@bsim_postgres:5432/bsim'
# OUT_CT lives under /work (bind-mounted from ./work) so it appears on the host
# at $STAGING_HOST; the final step moves it to $OUT_HOST.
OUT_CT=/work/signatures
STAGING_HOST="$ROOT/work/signatures"
OUT_HOST="$ROOT/signatures"
LIST_HOST="$ROOT/work/exes.list"
LIST_CT="/work/exes.list"

rm -rf "$STAGING_HOST"
docker exec bsim-foundry-ghidra mkdir -p "$OUT_CT"

echo "Listing executables..."
if [ "$ONLY_NON_O0" = 1 ]; then
  # Filter: only names whose tail is -O<digit|s|z> (i.e. *not* the empty/-O0 suffix).
  docker exec bsim-foundry-ghidra /ghidra/support/bsim listexes "$BSIM_URL" --limit 999999 \
    2>/dev/null \
    | awk 'NF>=2 && $2 ~ /@/ && $2 ~ /-O[0-9SsZz]$/ {print $1, $2}' \
    > "$LIST_HOST"
else
  docker exec bsim-foundry-ghidra /ghidra/support/bsim listexes "$BSIM_URL" --limit 999999 \
    2>/dev/null \
    | awk 'NF>=2 && $2 ~ /@/ {print $1, $2}' \
    > "$LIST_HOST"
fi
total=$(wc -l < "$LIST_HOST")
echo "Found $total executables. Dumping..."

# Run the dump loop in a single docker exec — still spawns a JVM per md5
# (~1.5s each), but avoids docker-exec setup overhead.
docker exec bsim-foundry-ghidra bash -c '
  set -e
  BSIM_URL="'"$BSIM_URL"'"
  OUT="'"$OUT_CT"'"
  i=0
  total=$(wc -l < "'"$LIST_CT"'")
  while read -r md5 name; do
    i=$((i+1))
    safe=$(echo "$name" | tr "@/" "__")
    mkdir -p "$OUT/$safe"
    if ! /ghidra/support/bsim dumpsigs "$BSIM_URL" "$OUT/$safe" --md5 "$md5" >/dev/null 2>&1; then
      echo "  WARN failed: $md5 ($name)"
    fi
    if [ $((i % 100)) -eq 0 ]; then
      echo "  ... $i / $total"
    fi
  done < "'"$LIST_CT"'"
  echo "  done $i / $total"
'

if [ "$ONLY_NON_O0" = 1 ]; then
  # Incremental: merge new per-name dirs into existing signatures/.
  mkdir -p "$OUT_HOST"
  if [ -d "$STAGING_HOST" ] && [ -n "$(ls -A "$STAGING_HOST" 2>/dev/null)" ]; then
    cp -r "$STAGING_HOST"/. "$OUT_HOST"/
  fi
  rm -rf "$STAGING_HOST"
else
  rm -rf "$OUT_HOST"
  mv "$STAGING_HOST" "$OUT_HOST"
fi
echo "Done. Dumped under $OUT_HOST/"
du -sh "$OUT_HOST"
