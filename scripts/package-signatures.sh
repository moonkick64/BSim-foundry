#!/usr/bin/env bash
# Package signatures/ into a gzipped tarball for distribution as a GitHub
# Release asset. The signature corpus is intentionally kept out of git (see
# .gitignore) because it is large, generated, and changes wholesale on every
# re-dump — committing it would bloat history unboundedly.
#
# Usage:
#   ./scripts/package-signatures.sh            # -> signatures.tar.gz
#   ./scripts/package-signatures.sh v1.1.0     # -> signatures-v1.1.0.tar.gz
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT"

if [ ! -d signatures ] || [ -z "$(ls -A signatures 2>/dev/null)" ]; then
  echo "signatures/ is missing or empty. Run ./scripts/dump-signatures.sh first."
  exit 1
fi

tag="${1:-}"
if [ -n "$tag" ]; then
  out="signatures-${tag}.tar.gz"
else
  out="signatures.tar.gz"
fi

n_dirs=$(find signatures -mindepth 1 -maxdepth 1 -type d | wc -l)
n_files=$(find signatures -type f | wc -l)
echo "Packaging $n_dirs corpus dirs / $n_files signature files -> $out"

tar czf "$out" signatures

echo "Done:"
ls -lh "$out" | awk '{print "  "$9"  "$5}'
echo
echo "Upload as a release asset, e.g.:"
echo "  gh release create <tag> $out -t '<title>' -n '<notes>'"
echo "Consumers download + unpack at the repo root, then run"
echo "  ./scripts/restore-signatures.sh"
