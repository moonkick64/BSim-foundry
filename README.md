# bsim-foundry-sighthouse

An experiment in building a binary similarity signature corpus for common OSS
C/C++ libraries, using [Quarkslab/SightHouse](https://github.com/quarkslab/sighthouse)
and Ghidra's **BSIM (Binary SIMilarity)** engine.

Libraries are built from [SCA-Benchmark](https://github.com/moonkick64/SCA-Benchmark)
and ingested into a Ghidra BSIM database through SightHouse's analyzer pipeline.
The output is a labelled signature DB and its XML dump (distributed via GitHub
Releases).

## Dataset

| | |
| ----------------------------- | ------------------------------------------------ |
| Libraries                     | 29 (zlib, openssl, mbedtls, sqlite, libcurl, …) |
| Architectures                 | x86_64, arm64                                    |
| Optimization                  | `-O0`, `-O2`                                      |
| BSIM executables (`.o` units) | 10,832                                           |
| Signed functions              | 257,724                                          |

Each function is labelled `<library>@<version>-<arch>[-O<level>]` — for example,
`zlib@1.3.1-x86_64` or `openssl@3.6.0-arm64-O2`.

## Quick start

```bash
# 1. Bring up the BSIM database
./scripts/bootstrap.sh

# 2. Fetch the signatures from a Release and load them
gh release download v1.0.0 --pattern 'signatures-*.tar.gz'
tar xzf signatures-v1.0.0.tar.gz
./scripts/restore-signatures.sh
```

At this point `bsim_postgres` is populated. From there:

- **Ghidra GUI**: add `postgresql://user@localhost:5432/bsim` as a Postgres
  BSim Server (BSim menu in the Project Manager), then in the CodeBrowser use
  `BSim → Search Functions`.
- **Via SightHouse (IDA / Binary Ninja / Ghidra plugins)**: you also need to
  run SightHouse's frontend. See
  `sighthouse/doc/docs/frontend/quickstart.md`.

## Building / extending the corpus

To add libraries, architectures, or optimization levels — or to rebuild from
scratch — see [BUILDING.md](BUILDING.md).

## License

MIT — see [LICENSE](LICENSE). Dependencies keep their own licenses:
- Quarkslab/SightHouse — MIT
- Ghidra — Apache 2.0
- The libraries themselves — see SCA-Benchmark/`libraries.json`.
