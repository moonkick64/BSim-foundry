#!/usr/bin/env bash
# Bootstrap BSim-foundry: clone sighthouse, bring up docker compose,
# compile SightHouseAnalyzerScript inside the Ghidra container.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT"

if [ ! -d sighthouse ]; then
  echo ">>> cloning Quarkslab/sighthouse"
  git clone --depth 1 https://github.com/quarkslab/sighthouse.git
fi

mkdir -p work/scripts work/extracted work/configs work/projects work/logs

if [ ! -f work/scripts/SightHouseAnalyzerScript.java ]; then
  cp sighthouse/sighthouse-pipeline/src/sighthouse/pipeline/core_modules/GhidraAnalyzer/ghidrascripts/SightHouseAnalyzerScript.java \
     work/scripts/
fi

echo ">>> starting docker compose"
docker compose up -d

echo ">>> waiting for bsim_postgres healthy"
for _ in $(seq 1 30); do
  state=$(docker inspect -f '{{.State.Health.Status}}' bsim-foundry-postgres 2>/dev/null || echo "starting")
  if [ "$state" = "healthy" ]; then break; fi
  sleep 2
done

echo ">>> waiting for create_bsim_db (one-shot) to finish"
docker wait bsim-foundry-create-db >/dev/null 2>&1 || true

if [ ! -f work/scripts/SightHouseAnalyzerScript.class ]; then
  echo ">>> compiling SightHouseAnalyzerScript.java"
  docker exec bsim-foundry-ghidra bash -c '
    JARS=$(find /ghidra -name "*.jar" | tr "\n" ":")
    cd /work/scripts && javac -g -d /work/scripts -sourcepath /work/scripts \
      -cp ".:$JARS" -proc:none SightHouseAnalyzerScript.java
  '
fi

echo ">>> bootstrap complete"
echo ">>> next: python3 ingest.py"
