#!/usr/bin/env python3
"""
BSim-foundry ingestion script.

For each (library, arch), extracts .o files from the static archive built by
SCA-Benchmark/scripts/builder.py, then runs Ghidra headless inside the
bsim-foundry-ghidra container with SightHouseAnalyzerScript to push BSIM
signatures into the bsim_postgres container.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).parent.resolve()
# Path to the SCA-Benchmark artifacts tree (static .a archives). Override via
# the SCA_ARTIFACTS env var; defaults to a sibling checkout of SCA-Benchmark.
ARTIFACTS_HOST = Path(
    os.environ.get("SCA_ARTIFACTS", ROOT.parent / "SCA-Benchmark" / "artifacts")
)
WORK_HOST = ROOT / "work"
WORK_CT = "/work"
GHIDRA_CT = "bsim-foundry-ghidra"
BSIM_URL = "postgresql://user@bsim_postgres:5432/bsim"

# rapidjson is header-only — no .a, skip
SKIP_LIBS = {"rapidjson"}

# Library version map (from SCA-Benchmark/libraries.json)
LIB_VERSIONS = {
    "zlib": "1.3.1",
    "openssl": "3.6.0",
    "libpng": "1.6.53",
    "mbedtls": "3.6.3",
    "sqlite": "3.47.2",
    "libsodium": "1.0.20",
    "expat": "2.6.4",
    "zstd": "1.5.6",
    "pcre2": "10.44",
    "bzip2": "1.0.8",
    "cjson": "1.7.18",
    "libjpeg-turbo": "3.1.0",
    "libwebp": "1.4.0",
    "libtiff": "4.7.0",
    "giflib": "5.2.2",
    "libxml2": "2.13.5",
    "nghttp2": "1.68.0",
    "libpcap": "1.10.6",
    "libarchive": "3.8.5",
    "lz4": "1.10.0",
    "libevent": "2.1.12",
    "c-ares": "1.34.6",
    "ncurses": "6.5",
    "libgmp": "6.3.0",
    "readline": "8.2",
    "wolfssl": "5.7.4",
    "lua": "5.4.7",
    "libuv": "1.49.2",
    "libcurl": "8.12.1",
}

ARCHES = ["x86_64", "arm64"]
OPT_LEVELS = ["O0", "O1", "O2", "O3", "Os", "Oz"]


def opt_suffix(opt: str) -> str:
    """Suffix appended to the BSIM exe metadata / project dir.

    O0 keeps the historical empty suffix so the existing -O0 corpus stays
    addressable as e.g. `zlib@1.3.1-x86_64`. Other opt levels get an explicit
    `-O2` tail.
    """
    return "" if opt == "O0" else f"-{opt}"


def list_libraries():
    libs = []
    for arch in ARCHES:
        for p in sorted((ARTIFACTS_HOST / arch).iterdir()):
            if p.is_dir() and p.name not in SKIP_LIBS:
                libs.append(p.name)
    return sorted(set(libs))


def find_static_archives(lib: str, arch: str) -> list[Path]:
    # openssl's x86_64 build installs into lib64/ instead of lib/
    for sub in ("lib", "lib64"):
        lib_dir = ARTIFACTS_HOST / arch / lib / sub
        if lib_dir.is_dir():
            archives = sorted(lib_dir.glob("*.a"))
            if archives:
                return archives
    return []


def extract_objs(lib: str, arch: str, opt: str, archives: list[Path]) -> Path:
    """Extract .o files from .a archives into a per-(lib,arch,opt) directory."""
    suffix = opt_suffix(opt)
    dst = WORK_HOST / "extracted" / f"{arch}{suffix}" / lib
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True, exist_ok=True)

    for ar_file in archives:
        # Use a subdirectory per archive to avoid name collisions across archives
        ar_dst = dst / ar_file.stem
        ar_dst.mkdir(exist_ok=True)
        subprocess.run(["ar", "x", str(ar_file)], cwd=ar_dst, check=True)
    return dst


def write_config(lib: str, arch: str, opt: str, extracted_host: Path) -> Path:
    """Write the analyzer config.json. Paths are container-side."""
    version = LIB_VERSIONS.get(lib, "unknown")
    suffix = opt_suffix(opt)
    cfg_dir_host = WORK_HOST / "configs" / f"{arch}{suffix}" / lib
    cfg_dir_host.mkdir(parents=True, exist_ok=True)
    cfg_path_host = cfg_dir_host / "config.json"

    extracted_ct = f"{WORK_CT}/extracted/{arch}{suffix}/{lib}"
    config = {
        "directory": extracted_ct,
        "metadata": json.dumps({
            "metadata": [[lib, f"{version}-{arch}{suffix}"]],
            "origin": f"SCA-Benchmark:{lib}:{version}:{arch}:{opt}",
        }),
        "format": "simple",
        "bsim": {
            "urls": [BSIM_URL],
            "min_instructions": 10,
            "max_instructions": 0,
            "databases": [{"url": BSIM_URL, "username": "user", "password": ""}],
        },
    }
    cfg_path_host.write_text(json.dumps(config, indent=2))
    return cfg_path_host


def run_ghidra(lib: str, arch: str, opt: str, cfg_path_host: Path) -> tuple[int, str]:
    """Run Ghidra headless to ingest signatures. Returns (returncode, log_tail)."""
    suffix = opt_suffix(opt)
    tag = f"{lib}-{arch}{suffix}"
    cfg_ct = f"{WORK_CT}/configs/{arch}{suffix}/{lib}/config.json"
    proj_dir_ct = f"{WORK_CT}/projects/{tag}"
    log_host = WORK_HOST / "logs" / f"{tag}.log"
    log_ct = f"{WORK_CT}/logs/{tag}.log"

    proj_dir_host = WORK_HOST / "projects" / tag
    if proj_dir_host.exists():
        shutil.rmtree(proj_dir_host)
    proj_dir_host.mkdir(parents=True, exist_ok=True)

    cmd = [
        "docker", "exec",
        "-e", "_JAVA_OPTIONS=-Duser.name=user",
        GHIDRA_CT,
        "/ghidra/support/analyzeHeadless",
        proj_dir_ct, "tmpproj",
        "-log", log_ct,
        "-scriptPath", f"{WORK_CT}/scripts",
        "-preScript", "SightHouseAnalyzerScript.class", cfg_ct,
    ]

    t0 = time.time()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    elapsed = time.time() - t0

    log_tail = ""
    if log_host.exists():
        with open(log_host) as fp:
            lines = fp.read().splitlines()
            log_tail = "\n".join(lines[-20:])
    elif proc.stderr:
        log_tail = proc.stderr[-2000:]

    print(f"    -> exit={proc.returncode} elapsed={elapsed:.1f}s")
    return proc.returncode, log_tail


def get_exe_count() -> int:
    r = subprocess.run(
        ["docker", "exec", GHIDRA_CT,
         "/ghidra/support/bsim", "getexecount", BSIM_URL],
        capture_output=True, text=True,
    )
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.isdigit():
            return int(line)
        if "Total" in line or "count" in line.lower():
            for tok in line.replace(":", " ").split():
                if tok.isdigit():
                    return int(tok)
    return -1


def ingest(lib: str, arch: str, opt: str) -> bool:
    print(f"[{lib} / {arch} / {opt}]")
    archives = find_static_archives(lib, arch)
    if not archives:
        print(f"    SKIP (no .a found in {ARTIFACTS_HOST}/{arch}/{lib}/lib)")
        return False
    print(f"    .a files: {[a.name for a in archives]}")

    extracted = extract_objs(lib, arch, opt, archives)
    n_obj = sum(1 for _ in extracted.rglob("*.o"))
    print(f"    extracted {n_obj} .o files -> {extracted}")
    if n_obj == 0:
        return False

    cfg = write_config(lib, arch, opt, extracted)
    rc, log_tail = run_ghidra(lib, arch, opt, cfg)
    if rc != 0:
        print(f"    FAILED. log tail:\n{log_tail}")
        return False

    # Reclaim disk: signatures are already in postgres, so the per-lib Ghidra
    # project and extracted .o files are no longer needed.
    suffix = opt_suffix(opt)
    tag = f"{lib}-{arch}{suffix}"
    proj_dir_host = WORK_HOST / "projects" / tag
    if proj_dir_host.exists():
        shutil.rmtree(proj_dir_host, ignore_errors=True)
    if extracted.exists():
        shutil.rmtree(extracted, ignore_errors=True)
    return True


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--lib", action="append", default=[],
                   help="ingest only the given library (repeat to allow several)")
    p.add_argument("--arch", action="append", default=[],
                   choices=ARCHES, help="ingest only the given arch")
    p.add_argument("--opt-level", default="O0", choices=OPT_LEVELS,
                   help="Optimization level the artifacts/ was built with "
                        "(only affects BSIM metadata tag, not the build itself). "
                        "O0 keeps the historical empty suffix.")
    p.add_argument("--list", action="store_true",
                   help="list available libraries and exit")
    args = p.parse_args()

    if args.list:
        for lib in list_libraries():
            print(lib)
        return

    libs = args.lib or list_libraries()
    arches = args.arch or ARCHES
    opt = args.opt_level

    before = get_exe_count()
    print(f"BSIM DB exe count before: {before}")

    failures = []
    successes = 0
    for lib in libs:
        if lib in SKIP_LIBS:
            print(f"[{lib}] SKIPPED (header-only / SKIP_LIBS)")
            continue
        for arch in arches:
            ok = ingest(lib, arch, opt)
            if ok:
                successes += 1
            else:
                failures.append(f"{lib}/{arch}/{opt}")

    after = get_exe_count()
    print(f"\nBSIM DB exe count: {before} -> {after} (delta {after - before})")
    print(f"Successes: {successes}, Failures: {len(failures)}")
    if failures:
        print("Failed: " + ", ".join(failures))
        sys.exit(1)


if __name__ == "__main__":
    main()
