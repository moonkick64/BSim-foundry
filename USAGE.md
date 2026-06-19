# Using the signatures

This document covers how to **use** existing BSim-foundry signatures to detect
OSS library functions in an unknown binary. To *build or extend* the signatures, see
[BUILDING.md](BUILDING.md); to get the database populated in the first place, see the
**Quick start** in [README.md](README.md).

Everything below assumes `bsim_postgres` is already populated (`./scripts/bootstrap.sh` +
`./scripts/restore-signatures.sh`) and reachable at
`postgresql://user@localhost:5432/bsim`.

## What the signatures can and cannot do

- **Can**: identify which covered libraries a binary embeds, and name individual functions
  (e.g. a stripped `FUN_0010abcd` → `inflate_fast` from `zlib@1.3.1-x86_64`). Works on
  stripped, statically-linked, real-world binaries, and tolerates minor version / `-O`
  differences (matching is on decompiled structure, not names).
- **Cannot**: recover full C prototypes / data types. These are **signature-only**
  — the source programs are discarded during ingest — so only the function *name* and
  library label are stored.

> ⚠️ **Ghidra's native "Apply Name / Apply Signature" buttons do not work** with these
> signatures. They try to open the matched *source program* to copy its prototype, which a
> signature-only database does not contain, so they error out. Use the GUI for
> **search / identification only**, or use the headless `BSimRename` script below (which
> applies the stored name without needing a source program), or the SightHouse plugin.

## Three ways to consume

| Path | Tool | What you get |
| ---- | ---- | ------------ |
| A. Headless scripts | your own Ghidra | batch identify + auto-rename (CI-friendly) |
| B. Ghidra GUI | your own Ghidra | interactive BSim search (identify only) |
| C. SightHouse plugin | IDA / Binary Ninja / Ghidra | matches as comments / tags |

### A. Headless: identify or rename (recommended for automation)

[`scripts/identify.sh`](scripts/identify.sh) drives **your local Ghidra** (not the build
container) to import a binary, analyze it, and query the BSim DB. It wraps two scripts in
[`ghidra_scripts/`](ghidra_scripts/): `BSimIdentify.java` (read-only report) and
`BSimRename.java` (renames confident matches).

```bash
export GHIDRA_INSTALL_DIR=/opt/ghidra            # Ghidra 11.3+

# Identify embedded libraries (read-only)
./scripts/identify.sh ./suspect.bin

# Rename functions in-place; open the resulting project in the GUI to review
MODE=rename ./scripts/identify.sh ./suspect.bin
#   -> writes bsim-out/suspect.bin/suspect.bin.gpr
```

Knobs (environment variables): `MODE` (`identify`|`rename`), `BSIM_URL`, `SIM` (min
similarity, default `0.75`), `SIG` (min significance, default `20`), `OUTDIR`.

Example identify output on a stripped distro `libz.so.1.3`:

```
detected libraries (by significance sum — higher = real):
  library             funcs     signifSum
  zlib                   75         16202
  libarchive              1            33
  openssl                 1            20
```

**Read it by significance sum, not similarity.** A genuinely embedded library has a large
significance sum across many functions; tiny functions (significance < ~20) match many
libraries at similarity 1.0 and are noise. The `SIG` floor filters them — raise it to
`40+` for fewer false positives, lower it to surface more (and noisier) matches.

`BSimRename` only renames functions that are currently unnamed (`FUN_xxxx`), so it never
clobbers real symbols, and it leaves an evidence plate comment + a `BSim` bookmark on each
rename so you can audit what it did (Window → Bookmarks, category `BSim`).

You can also call the scripts directly without the wrapper:

```bash
$GHIDRA_INSTALL_DIR/support/analyzeHeadless ./out tmp -import ./suspect.bin \
  -scriptPath ghidra_scripts -postScript BSimRename.java \
  postgresql://user@localhost:5432/bsim 0.75 20
```

### B. Ghidra GUI (interactive search)

1. **Register the server** (once): in the Ghidra Project window, BSim → add a **PostgreSQL**
   server — host `localhost`, port `5432`, database `bsim`, user `user` (no password). Or
   paste the URL `postgresql://user@localhost:5432/bsim`.
2. Import your binary, open it in the CodeBrowser, and let auto-analysis finish.
3. **BSim → Search Functions…** Set Similarity ≈ `0.7`. Run with no selection to query the
   whole program.
4. The results table's **Executable** column is the library label (e.g.
   `zlib@1.3.1-x86_64`). **BSim → Perform Overview…** gives a program-wide, per-executable
   summary — sort by it to see which libraries dominate.

Remember: **search works, but the Apply buttons do not** (see the warning above).

### C. SightHouse plugin (IDA / Binary Ninja / Ghidra)

SightHouse provides client plugins that query the same BSim backend through its frontend
and annotate matches (IDA: comments, Binary Ninja: tags, Ghidra: plate comment + bookmark
— it does **not** rename). Use this if you work in IDA/Binary Ninja, or want an
auth-gated, multi-user service instead of handing out direct Postgres access.

1. Start the frontend (bundled in [docker-compose.yml](docker-compose.yml)); the API
   listens on `127.0.0.1:6669` (default login `user` / `password`).
2. Install a client:
   ```bash
   pip install sighthouse-client
   sighthouse client install ida    --ida-dir   /path/to/ida
   sighthouse client install ghidra --ghidra-install-dir /path/to/ghidra
   sighthouse client install binja
   ```
3. Run the plugin in your tool, point it at `http://127.0.0.1:6669` with the credentials,
   and matches appear as annotations.

See the upstream docs under `sighthouse/doc/docs/clients/` (installation + quickstart) for
the full client walkthrough.
