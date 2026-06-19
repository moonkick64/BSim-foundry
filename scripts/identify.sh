#!/usr/bin/env bash
# Identify (and optionally rename) the covered libraries embedded in a target binary,
# using your *local* Ghidra against the restored BSim database.
#
# Unlike the build pipeline (which runs Ghidra inside the bsim-foundry-ghidra container),
# consumption uses YOUR own Ghidra to analyze YOUR binary, then queries the BSim server.
#
# Prerequisites:
#   - The BSim DB is up and populated (./scripts/bootstrap.sh + ./scripts/restore-signatures.sh).
#   - GHIDRA_INSTALL_DIR points at a Ghidra 11.3+ install (has support/analyzeHeadless).
#
# Usage:
#   GHIDRA_INSTALL_DIR=/opt/ghidra ./scripts/identify.sh <binary>
#   GHIDRA_INSTALL_DIR=/opt/ghidra MODE=rename ./scripts/identify.sh <binary>
#
# Env knobs:
#   MODE      identify (default, read-only report) | rename (applies names + comments)
#   BSIM_URL  default postgresql://user@localhost:5432/bsim
#   SIM       min similarity   (default 0.75)
#   SIG       min significance (default 20 ; raise to 40+ to cut false positives)
#   OUTDIR    Ghidra project dir (default ./bsim-out/<binary>); kept so you can open
#             the result in the GUI (Window -> Functions / Bookmarks).
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)"

if [ $# -lt 1 ]; then
  echo "usage: GHIDRA_INSTALL_DIR=/path/to/ghidra $0 <binary>" >&2
  exit 2
fi
TARGET="$1"
[ -f "$TARGET" ] || { echo "no such file: $TARGET" >&2; exit 2; }

: "${GHIDRA_INSTALL_DIR:?set GHIDRA_INSTALL_DIR to your Ghidra install}"
HEADLESS="$GHIDRA_INSTALL_DIR/support/analyzeHeadless"
[ -x "$HEADLESS" ] || { echo "analyzeHeadless not found under $GHIDRA_INSTALL_DIR/support" >&2; exit 2; }

MODE="${MODE:-identify}"
BSIM_URL="${BSIM_URL:-postgresql://user@localhost:5432/bsim}"
SIM="${SIM:-0.75}"
SIG="${SIG:-20}"
name="$(basename "$TARGET")"
OUTDIR="${OUTDIR:-$ROOT/bsim-out/$name}"

case "$MODE" in
  identify) SCRIPT=BSimIdentify.java; ARGS=("$BSIM_URL" "$SIM" "$SIG") ;;
  rename)   SCRIPT=BSimRename.java;   ARGS=("$BSIM_URL" "$SIM" "$SIG") ;;
  *) echo "MODE must be 'identify' or 'rename'" >&2; exit 2 ;;
esac

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

echo ">>> MODE=$MODE  BSIM_URL=$BSIM_URL  SIM=$SIM SIG=$SIG"
echo ">>> importing + analyzing $name with your Ghidra ..."
"$HEADLESS" "$OUTDIR" "$name" \
  -import "$TARGET" \
  -scriptPath "$ROOT/ghidra_scripts" \
  -postScript "$SCRIPT" "${ARGS[@]}"

if [ "$MODE" = rename ]; then
  echo ">>> done. Open the result in the Ghidra GUI:"
  echo "      $OUTDIR/$name.gpr"
fi
