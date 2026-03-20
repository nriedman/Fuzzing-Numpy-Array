# Atheris fuzzer for NumPy 2.2.5 (targeting numpy.round)
#
# Two NumPy builds are produced:
#   site-packages    – ASAN + fuzzer-no-link  (used while fuzzing)
#   /build/numpy-cov – source-based coverage  (used for coverage reports)
#
# ── Build ─────────────────────────────────────────────────────────────────────
#
#   docker build -t numpy-fuzz .
#
# ── Fuzz ──────────────────────────────────────────────────────────────────────
#
#   docker run --rm -it \
#     -v /home/student/shared/FuzzingNumpyArray:/home/student/shared/FuzzingNumpyArray \
#     numpy-fuzz bash
#
#   cd /home/student/shared/FuzzingNumpyArray
#   python3.11 fuzz_numpy_round.py corpus/
#
# ── Coverage report ───────────────────────────────────────────────────────────
#
#   ./run-coverage-report.sh fuzz_numpy_round.py corpus/ coverage-report/

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

# ── ASAN runtime options ──────────────────────────────────────────────────────
# detect_leaks=0 is essential — CPython's allocator has intentional shutdown-time
# leaks that would otherwise abort every run before any fuzzing happens.
# abort_on_error and halt_on_error are intentionally omitted: setting them causes
# ASAN to kill the process at the signal handler level, which prevents libFuzzer's
# -ignore_crashes=1 from working. Set them explicitly if you want hard-stop
# behaviour in CI:
#   ASAN_OPTIONS="detect_leaks=0:abort_on_error=1:halt_on_error=1" python3.11 ...
ENV ASAN_OPTIONS="detect_leaks=0"

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

RUN printf '[built-in options]\n\
c_args        = ['\''-O1'\'', '\''-fno-omit-frame-pointer'\'', '\''-fsanitize=address,fuzzer-no-link'\'']\n\
cpp_args      = ['\''-O1'\'', '\''-fno-omit-frame-pointer'\'', '\''-fsanitize=address,fuzzer-no-link'\'']\n\
c_link_args   = ['\''-fsanitize=address'\'']\n\
cpp_link_args = ['\''-fsanitize=address'\'']\n' > /build/asan-native.ini

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
# .profraw file at runtime (-fprofile-instr-generate). llvm-profdata merges
# .profraw files from multiple runs, and llvm-cov renders the result as HTML,
# text, or LCOV — annotated down to individual source lines and branches.
#
# Kept separate from the fuzz build because the two instrumentation schemes
# write to different runtime data structures and cannot share a process.
# Installed into /build/numpy-cov so it doesn't clobber site-packages.

RUN printf '[built-in options]\n\
c_args        = ['\''-O1'\'', '\''-fno-omit-frame-pointer'\'', '\''-fprofile-instr-generate'\'', '\''-fcoverage-mapping'\'']\n\
cpp_args      = ['\''-O1'\'', '\''-fno-omit-frame-pointer'\'', '\''-fprofile-instr-generate'\'', '\''-fcoverage-mapping'\'']\n\
c_link_args   = ['\''-fprofile-instr-generate'\'']\n\
cpp_link_args = ['\''-fprofile-instr-generate'\'']\n' > /build/cov-native.ini

RUN /usr/bin/python3.11 -m pip install \
        --no-build-isolation \
        --target=/build/numpy-cov \
        --config-settings=setup-args="--native-file=/build/cov-native.ini" \
        .

# ── working directory ─────────────────────────────────────────────────────────
WORKDIR /home/student