# bsim-foundry

Build Ghidra **BSIM (Binary SIMilarity)** signatures for a curated set of OSS
C/C++ libraries — using
[Quarkslab/sighthouse](https://github.com/quarkslab/sighthouse) for the BSIM
backend and the
[SCA-Benchmark](https://github.com/moonkick64/SCA-Benchmark) build pipeline
for the library corpus.

Output: a BSIM signature database (and dumped XML signatures under
`signatures/`) covering 29 OSS libraries × {x86_64, arm64} × one or more
optimization levels (the current corpus has both `-O0` and `-O2`, totaling
~10.8k BSIM executables).

## Library corpus

Sourced from SCA-Benchmark's `libraries.json` (30 libraries, all pinned to a
specific version). `rapidjson` is header-only and therefore excluded — 29
libraries remain.

zlib, openssl, libpng, mbedtls, sqlite, libsodium, expat, zstd, pcre2, bzip2,
cjson, libjpeg-turbo, libwebp, libtiff, giflib, libxml2, nghttp2, libpcap,
libarchive, lz4, libevent, c-ares, ncurses, libgmp, readline, wolfssl, lua,
libuv, libcurl.

Each library is built as a static archive (`.a`) for **x86_64** and **arm64**
by [SCA-Benchmark/scripts/builder.py](https://github.com/moonkick64/SCA-Benchmark/blob/main/scripts/builder.py).
The build flags are `-g -O0` by default; to build a second optimization
corpus (e.g. `-O2`), edit `OPT_FLAGS` in `builder.py`, rebuild, and re-run
`ingest.py --opt-level O2`. See **Multiple optimization levels** below.

## Architecture

```
                   .a archives                    .o files
SCA-Benchmark  ───────────────►  ingest.py  ───────────────►  Ghidra headless
artifacts/                       (ar x)                       (SightHouseAnalyzerScript)
                                                                     │
                                                                     ▼
                                                              bsim_postgres
                                                              (BSIM database)
                                                                     │
                                                                     ▼
                                                              bsim dumpsigs
                                                                     │
                                                                     ▼
                                                              signatures/*.xml
```

## Prerequisites

- Docker 24+ with `docker compose` plugin
- Python 3.10+
- `ar` (binutils) on the host
- A local checkout of
  [SCA-Benchmark](https://github.com/moonkick64/SCA-Benchmark) with the 30
  libraries already built for x86_64 and arm64 under
  `artifacts/<arch>/<lib>/lib/*.a`. By default both `ingest.py` and
  `docker-compose.yml` look for a **sibling** checkout at
  `../SCA-Benchmark/artifacts`. If yours is elsewhere, set the `SCA_ARTIFACTS`
  environment variable (e.g. in a `.env` file next to `docker-compose.yml`):
  ```bash
  echo 'SCA_ARTIFACTS=/path/to/SCA-Benchmark/artifacts' > .env
  export SCA_ARTIFACTS=/path/to/SCA-Benchmark/artifacts   # for ingest.py
  ```

Docker images used (pulled from upstream, no local build needed):
- `ghcr.io/quarkslab/sighthouse/ghidraheadless:1.0.3` (Ghidra 11.4.1)
- `ghcr.io/quarkslab/sighthouse/ghidra-bsim-postgres:1.0.3`
- `ghcr.io/quarkslab/sighthouse/create_bsim_db:1.0.3`

## Bootstrap

```bash
# 1. Clone Quarkslab/sighthouse (provides SightHouseAnalyzerScript.java)
git clone https://github.com/quarkslab/sighthouse.git

# 2. Stand up bsim_postgres + create the database
docker compose up -d
# wait until create_bsim_db has finished (it prints "Created database: Medium No Size")

# 3. Stage the analyzer script and compile it inside the Ghidra container
mkdir -p work/scripts work/extracted work/configs work/projects work/logs
cp sighthouse/sighthouse-pipeline/src/sighthouse/pipeline/core_modules/GhidraAnalyzer/ghidrascripts/SightHouseAnalyzerScript.java work/scripts/
docker exec bsim-foundry-ghidra bash -c '
  JARS=$(find /ghidra -name "*.jar" | tr "\n" ":")
  cd /work/scripts && javac -g -d /work/scripts -sourcepath /work/scripts \
    -cp ".:$JARS" -proc:none SightHouseAnalyzerScript.java
'
```

## Ingest signatures

```bash
# Single library, single arch (PoC)
python3 ingest.py --lib zlib --arch x86_64

# All 29 libs × {x86_64, arm64} — takes ~1.5 to 2 hours
python3 ingest.py
```

Per library × arch, `ingest.py` does:
1. `ar x` each `.a` from `SCA-Benchmark/artifacts/<arch>/<lib>/lib/`
2. Writes `config.json` with the BSIM URL and per-library metadata
3. Runs `analyzeHeadless ... -preScript SightHouseAnalyzerScript.class`,
   which imports each `.o`, decompiles, and inserts BSIM signatures.
4. Deletes the per-library Ghidra project and extracted `.o` files (the
   signatures live in postgres now, so the scratch dirs are disposable —
   skipping this step makes a full run easily exceed 30 GB of disk).

## Multiple optimization levels

The same library compiled with different `-O` flags produces different machine
code and therefore different BSIM signatures. `ingest.py` supports tagging
each ingest with an optimization level so multiple opt-level corpora can
coexist in the same BSIM database.

```bash
# Default: tag as -O0 (suffix omitted for backward compatibility).
python3 ingest.py

# After rebuilding SCA-Benchmark with -O2, swap the artifacts dir and
# re-ingest with --opt-level O2.
python3 ingest.py --opt-level O2
```

**Suffix convention** (applied to BSIM exe metadata, per-arch dump dirs, and
the per-(lib,arch) Ghidra project dir under `work/projects/`):

| `--opt-level` | metadata tag                  | dump dir                          |
| ------------- | ----------------------------- | --------------------------------- |
| `O0` (default)| `zlib@1.3.1-x86_64`           | `signatures/zlib_1.3.1-x86_64/`   |
| `O2`          | `zlib@1.3.1-x86_64-O2`        | `signatures/zlib_1.3.1-x86_64-O2/`|
| `O3` / `Os` / `Oz` | `…-O3` / `…-Os` / `…-Oz` | analogous                         |

The `-O0` corpus keeps the historical empty suffix so the original ~5.5k-exe
release stays addressable under its original name. Any non-O0 level gets an
explicit `-O<n>` tail. The artifacts directory itself is **not** suffixed —
`ingest.py` reads from `SCA-Benchmark/artifacts/<arch>/<lib>/lib/*.a`
regardless of opt level, so you must rebuild artifacts before each
`--opt-level` ingest (keep prior artifacts around in `artifacts-O0/` etc. if
you want to re-ingest).

## Inspect the database

```bash
# Count executables
docker exec bsim-foundry-ghidra /ghidra/support/bsim \
  getexecount 'postgresql://user@bsim_postgres:5432/bsim'

# List executables (first 20)
docker exec bsim-foundry-ghidra /ghidra/support/bsim \
  listexes 'postgresql://user@bsim_postgres:5432/bsim'

# List functions for one executable (by name)
docker exec bsim-foundry-ghidra /ghidra/support/bsim \
  listfuncs 'postgresql://user@bsim_postgres:5432/bsim' --name 'zlib@1.3.1-x86_64'

# Same lib at -O2 (note the -O2 suffix on the metadata tag)
docker exec bsim-foundry-ghidra /ghidra/support/bsim \
  listfuncs 'postgresql://user@bsim_postgres:5432/bsim' --name 'zlib@1.3.1-x86_64-O2'
```

## Export signatures

```bash
# Full dump: replaces signatures/ with everything currently in the BSIM DB.
./scripts/dump-signatures.sh

# Incremental: only dump exes whose metadata ends in -O<n> (i.e. anything
# but the default -O0 suffix) and merge into the existing signatures/ tree.
# Useful after adding a second optimization corpus without re-dumping the
# multi-hour -O0 baseline.
./scripts/dump-signatures.sh --only-non-o0
```

Outputs live under `signatures/<lib>_<ver>-<arch>[-O<n>]/sigs_<md5>`.

## Distribution (Releases, not git)

The `signatures/` corpus (~380 MB raw, ~60 MB gzipped, 10k+ files) is **not**
tracked in git — it is generated, large, and changes wholesale on every
re-dump, which would bloat git history. It is shipped as a **GitHub Release
asset** instead.

```bash
# Package the current signatures/ into a tarball
./scripts/package-signatures.sh v1.1.0      # -> signatures-v1.1.0.tar.gz

# Publish (requires gh + push access)
gh release create v1.1.0 signatures-v1.1.0.tar.gz \
  -t 'bsim-foundry v1.1.0' -n 'O0 + O2 corpus, x86_64 + arm64'
```

## Restore signatures into a fresh DB

```bash
# 1. Fetch + unpack the corpus from a Release (skip if you dumped locally)
gh release download v1.1.0 --pattern 'signatures-*.tar.gz'
tar xzf signatures-v1.1.0.tar.gz       # -> signatures/

# 2. Commit into a freshly bootstrapped bsim_postgres
./scripts/restore-signatures.sh
```

## Notes / known limitations

- **rapidjson** is header-only; no `.a` is produced, so it has no BSIM
  signatures.
- Each `.o` file becomes a separate "executable" in BSIM. The library name,
  version, arch, and (for non-O0 builds) optimization level are attached as
  the executable's metadata tag (e.g. `zlib@1.3.1-x86_64`,
  `zlib@1.3.1-x86_64-O2`).
- Functions with fewer than **10 instructions** are filtered out
  (`SightHouseAnalyzerScript` default). To change this, edit the per-library
  `config.json` written by `ingest.py`.
- BSIM postgres is configured with the **`medium_nosize`** template
  (multi-arch, ~10M functions capacity).
- `signatures/` is **only** mounted into the host filesystem, not into the
  ghidra container. `restore-signatures.sh` therefore stages the tree under
  `work/signatures/` (which **is** bind-mounted) before invoking
  `commitsigs`. Duplicate commits against an already-populated DB are
  no-ops — `commitsigs` emits a `WARN ... is already ingested` log and
  skips the insert, so the script is safe to re-run.

## License

bsim-foundry's own code: see LICENSE.

Vendored / dependent components keep their own licenses:
- Quarkslab/sighthouse — MIT
- Ghidra — Apache 2.0
- Each library in the corpus — see SCA-Benchmark/libraries.json.
