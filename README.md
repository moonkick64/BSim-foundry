# BSim-foundry

An experiment in building a binary similarity signature corpus for common OSS
C/C++ libraries, using [Quarkslab/SightHouse](https://github.com/quarkslab/sighthouse)
and Ghidra's **BSim (Binary Similarity)** engine.

Libraries are built from [SCA-Benchmark](https://github.com/moonkick64/SCA-Benchmark)
and ingested into a Ghidra BSim database through SightHouse's analyzer pipeline.
The output is a labelled signature DB and its XML dump (distributed via GitHub
Releases).

## Dataset

| | |
| ----------------------------- | ------------------------------------------------ |
| Libraries                     | 29 (zlib, openssl, mbedtls, sqlite, libcurl, …) |
| Architectures                 | x86_64, arm64                                    |
| Optimization                  | `-O0`, `-O2`                                      |
| BSim executables (`.o` units) | 10,832                                           |
| Signed functions              | 257,724                                          |

Each function is labelled `<library>@<version>-<arch>[-O<level>]` — for example,
`zlib@1.3.1-x86_64` or `openssl@3.6.0-arm64-O2`.

## Quick start

```bash
# 1. Bring up the BSim database
./scripts/bootstrap.sh

# 2. Fetch the signatures from a Release and load them
gh release download v1.0.0 --pattern 'signatures-*.tar.gz'
tar xzf signatures-v1.0.0.tar.gz
./scripts/restore-signatures.sh
```

At this point `bsim_postgres` is populated. To detect library functions in an
unknown binary, you have three options — headless scripts, the Ghidra GUI, or the
SightHouse plugins:

```bash
# Headless: identify embedded libraries, or rename functions in-place.
export GHIDRA_INSTALL_DIR=/opt/ghidra
./scripts/identify.sh ./suspect.bin              # read-only report
MODE=rename ./scripts/identify.sh ./suspect.bin  # auto-rename + evidence comments
```

See **[USAGE.md](USAGE.md)** for all three paths, threshold tuning, and how to
read the results.

> ⚠️ This is a **signature-only** corpus, so Ghidra's native **Apply Name /
> Apply Signature** buttons error out (they need the matched source program,
> which isn't stored). Use the GUI for search/identification only, or the
> `BSimRename` script / SightHouse plugin to apply names. See USAGE.md.

## Building / extending the corpus

To add libraries, architectures, or optimization levels — or to rebuild from
scratch — see [BUILDING.md](BUILDING.md).

## License

MIT — see [LICENSE](LICENSE). Dependencies keep their own licenses:
- Quarkslab/SightHouse — MIT
- Ghidra — Apache 2.0
- The libraries themselves — see SCA-Benchmark/`libraries.json`.
