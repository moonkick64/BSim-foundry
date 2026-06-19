#!/usr/bin/env bash
# Load signatures/*.xml back into a fresh bsim_postgres.
# Assumes bootstrap.sh has already created an empty BSim database.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT"

BSIM_URL='postgresql://user@bsim_postgres:5432/bsim'
# Container path: only ./work is bind-mounted into bsim-foundry-ghidra, so the
# host-side signatures/ must be staged under ./work/signatures/ before
# commitsigs can read it.
STAGING_HOST="$ROOT/work/signatures"
OUT_CT=/work/signatures

if [ ! -d signatures ]; then
  echo "signatures/ directory not found. Run dump-signatures.sh first or unpack a release tarball."
  exit 1
fi

# Stage signatures/ into work/signatures/ so the ghidra container can read it.
rm -rf "$STAGING_HOST"
mkdir -p "$STAGING_HOST"
cp -r signatures/. "$STAGING_HOST"/

for dir in signatures/*/; do
  name=$(basename "$dir")
  echo "  -> committing $name"
  docker exec bsim-foundry-ghidra /ghidra/support/bsim \
    commitsigs "$BSIM_URL" "$OUT_CT/$name" >/dev/null 2>&1 || \
      echo "    (warning: commit failed for $name)"
done

rm -rf "$STAGING_HOST"

echo "Done. Exe count:"
docker exec bsim-foundry-ghidra /ghidra/support/bsim getexecount "$BSIM_URL"
