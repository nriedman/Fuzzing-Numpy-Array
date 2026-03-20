# Atheris fuzzer for NumPy 2.2.5 (targeting numpy.round)
#
# Two NumPy builds are produced:
#   /build/numpy-fuzz/     – ASAN + fuzzer-no-link  (used while fuzzing)
#   /build/numpy-cov/      – source-based coverage  (used for coverage reports)
#
# Workflow:
#   1. Fuzz:    docker run ... bash
#               python3.11 <harness.py> corpus/ [libfuzzer args]
#
#   2. Report:  run-coverage-report.sh corpus/ [report_dir]
#               → merges .profraw files, runs llvm-cov, opens HTML report

FROM ubuntu:22.04

# ── system deps ──────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        clang-14 \
        llvm-14 \
        llvm-14-dev \
        python3.11 \
        python3.11-dev \
        python3-pip \
        python3.11-venv \
        git \
        curl \
        wget \
        pkg-config \
        ninja-build \
        build-essential \
        libssl-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Make clang-14 the default compiler
RUN update-alternatives --install /usr/bin/clang   clang   /usr/bin/clang-14   100 \
 && update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-14 100 \
 && update-alternatives --install /usr/bin/llvm-config llvm-config \
        /usr/bin/llvm-config-14 100

ENV CC=clang
ENV CXX=clang++

# ── Python tooling ────────────────────────────────────────────────────────────
RUN python3.11 -m pip install --upgrade pip meson-python Cython wheel setuptools \
        "meson>=1.1" build

# ── atheris ───────────────────────────────────────────────────────────────────
RUN python3.11 -m pip install atheris

# ── ASAN runtime options (set early — applies to all subsequent RUN steps) ───
ENV ASAN_OPTIONS="detect_leaks=0:abort_on_error=0:halt_on_error=0"

# ── locate ASAN runtime and write a python3.11 wrapper that preloads it ──────
# Instrumented .so files reference ASAN symbols that the dynamic linker won't
# find on its own; LD_PRELOAD makes them available before any dlopen() call.
RUN ASAN_SO=$(clang-14 -print-file-name=libclang_rt.asan-x86_64.so) && \
    [ -f "$ASAN_SO" ] || ASAN_SO=$(clang-14 -print-file-name=libclang_rt.asan-aarch64.so) && \
    echo "Found ASAN runtime: $ASAN_SO" && \
    echo "$ASAN_SO" > /asan_so_path.txt

RUN echo '#!/bin/sh' > /usr/local/bin/python3.11 && \
    echo "export LD_PRELOAD=$(cat /asan_so_path.txt)" >> /usr/local/bin/python3.11 && \
    echo 'exec /usr/bin/python3.11 "$@"' >> /usr/local/bin/python3.11 && \
    chmod +x /usr/local/bin/python3.11

# ── download NumPy source once, reuse for both builds ────────────────────────
WORKDIR /build
RUN wget -q https://github.com/numpy/numpy/releases/download/v2.2.5/numpy-2.2.5.tar.gz \
    && tar xzf numpy-2.2.5.tar.gz

# ════════════════════════════════════════════════════════════════════════════
# BUILD 1 — fuzz build  (ASAN + fuzzer-no-link, installs into site-packages)
# ════════════════════════════════════════════════════════════════════════════
#
# Uses a meson native file to inject sanitizer flags into project targets only,
# NOT into meson's own compiler sanity-check binaries (which would fail because
# they can't run under ASAN without LD_PRELOAD in meson's subprocess context).

WORKDIR /build/numpy-2.2.5

RUN cat > /build/asan-native.ini << 'INI'
[built-in options]
# -fsanitize=address        – AddressSanitizer: catches memory errors at runtime
# -fsanitize=fuzzer-no-link – libFuzzer edge coverage instrumentation; "no-link"
#                             means atheris provides the fuzzer driver, not clang.
#                             Must appear in compile flags only, not link flags,
#                             or the linker will try to pull in a duplicate main().
c_args        = ['-O1', '-fno-omit-frame-pointer', '-fsanitize=address,fuzzer-no-link']
cpp_args      = ['-O1', '-fno-omit-frame-pointer', '-fsanitize=address,fuzzer-no-link']
c_link_args   = ['-fsanitize=address']
cpp_link_args = ['-fsanitize=address']
INI

RUN /usr/bin/python3.11 -m pip install \
        --no-build-isolation \
        --config-settings=setup-args="--native-file=/build/asan-native.ini" \
        .

RUN cd / && python3.11 -c "import numpy; print('Fuzz build — NumPy', numpy.__version__)"

# ════════════════════════════════════════════════════════════════════════════
# BUILD 2 — coverage build  (source-based coverage, installs into /build/numpy-cov)
# ════════════════════════════════════════════════════════════════════════════
#
# LLVM source-based coverage works by embedding a profile map into each .so
# at compile time (-fcoverage-mapping) and writing execution counts to a
# .profraw file at runtime (-fprofile-instr-generate).  llvm-profdata merges
# .profraw files from multiple runs, and llvm-cov renders the result as HTML,
# text, or LCOV — annotated down to individual source lines and branches.
#
# This build is kept separate from the fuzz build because:
#   - The two instrumentation schemes write to different runtime data structures
#     and cannot safely share a process.
#   - The coverage build does not need ASAN; adding it would slow replay down
#     and add noise to the profile data.
#   - We install into an isolated prefix (/build/numpy-cov) so the coverage
#     build's .so files don't overwrite the fuzz build's .so files in
#     site-packages.

RUN cat > /build/cov-native.ini << 'INI'
[built-in options]
# -fprofile-instr-generate  – emit instrumentation that writes a .profraw file
# -fcoverage-mapping        – embed source-location metadata into the binary so
#                             llvm-cov can map profile counts back to source lines
c_args        = ['-O1', '-fno-omit-frame-pointer', '-fprofile-instr-generate', '-fcoverage-mapping']
cpp_args      = ['-O1', '-fno-omit-frame-pointer', '-fprofile-instr-generate', '-fcoverage-mapping']
c_link_args   = ['-fprofile-instr-generate']
cpp_link_args = ['-fprofile-instr-generate']
INI

# Build into an isolated prefix so it doesn't clobber the fuzz build.
# We use pip's --target flag to put the coverage .so files in /build/numpy-cov.
RUN /usr/bin/python3.11 -m pip install \
        --no-build-isolation \
        --target=/build/numpy-cov \
        --config-settings=setup-args="--native-file=/build/cov-native.ini" \
        .

# ── coverage report helper script ────────────────────────────────────────────
# Usage inside the container:
#   run-coverage-report.sh <corpus_dir> [output_dir]
#
# It replays every input in the corpus through the coverage-instrumented NumPy,
# merges the resulting .profraw files, and produces an HTML report showing line,
# region, and branch coverage for all NumPy C source files.
RUN cat > /usr/local/bin/run-coverage-report.sh << 'SCRIPT'
#!/bin/sh
set -e

CORPUS_DIR=${1:?Usage: run-coverage-report.sh <corpus_dir> [output_dir]}
OUTPUT_DIR=${2:-/fuzz/coverage-report}
PROFRAW_DIR=$(mktemp -d)
NUMPY_COV_SO=$(find /build/numpy-cov -name '_multiarray_umath*.so' | head -1)
NUMPY_SRC=/build/numpy-2.2.5

echo "==> Replaying corpus inputs through coverage build..."
for input in "$CORPUS_DIR"/*; do
    [ -f "$input" ] || continue
    # Each run gets its own .profraw file (LLVM_PROFILE_FILE pattern %p = pid)
    LLVM_PROFILE_FILE="$PROFRAW_DIR/cov-%p.profraw" \
    PYTHONPATH=/build/numpy-cov \
    /usr/bin/python3.11 - "$input" << 'PYEOF'
import sys, struct
import numpy as np

data = open(sys.argv[1], 'rb').read()

# Minimal replay: mirror the logic in your harness so the same code paths fire.
# Edit this block to match your actual TestOneInput if it changes.
import atheris
fdp = atheris.FuzzedDataProvider(data)
try:
    list_size = fdp.ConsumeIntInRange(0, 5)
    arr = np.array([fdp.ConsumeFloat() for _ in range(list_size)])
    np.round(arr, fdp.ConsumeIntInRange(-2147483648, 2147483647))
except Exception:
    pass
PYEOF
done

echo "==> Merging .profraw files..."
llvm-profdata-14 merge \
    --sparse \
    --output="$PROFRAW_DIR/merged.profdata" \
    "$PROFRAW_DIR"/cov-*.profraw

echo "==> Generating HTML report in $OUTPUT_DIR ..."
mkdir -p "$OUTPUT_DIR"
llvm-cov-14 show \
    "$NUMPY_COV_SO" \
    --instr-profile="$PROFRAW_DIR/merged.profdata" \
    --source-dirs="$NUMPY_SRC" \
    --format=html \
    --output-dir="$OUTPUT_DIR" \
    --show-line-counts \
    --show-regions \
    --show-branch-summary

echo "==> Text summary:"
llvm-cov-14 report \
    "$NUMPY_COV_SO" \
    --instr-profile="$PROFRAW_DIR/merged.profdata" \
    --source-dirs="$NUMPY_SRC"

echo ""
echo "HTML report written to $OUTPUT_DIR/index.html"
SCRIPT

RUN chmod +x /usr/local/bin/run-coverage-report.sh

RUN mkdir -p /home/student
WORKDIR /home/student
