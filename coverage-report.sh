#!/bin/sh
# run-coverage-report.sh  —  replay a fuzzer corpus through the coverage-
# instrumented NumPy build and produce an HTML + text coverage report.
#
# Usage:
#   ./run-coverage-report.sh <harness.py> <corpus_dir> [report_dir]
#
# Example:
#   ./run-coverage-report.sh fuzz-round.py corpus/ coverage-report/
#
# We bypass libFuzzer entirely for replay and call TestOneInput directly.
# This avoids libFuzzer's seed-corpus handling quirks and ensures the
# coverage runtime actually writes .profraw files.
#
# We use /usr/bin/python3.11 with -S (skip site.py) so site-packages is
# never added to sys.path, allowing /build/numpy-cov to win for numpy.
# The ASAN wrapper at /usr/local/bin/python3.11 is bypassed because the
# coverage build has no ASAN instrumentation.

set -e

HARNESS=${1:?Usage: run-coverage-report.sh <harness.py> <corpus_dir> [report_dir]}
CORPUS_DIR=${2:?Usage: run-coverage-report.sh <harness.py> <corpus_dir> [report_dir]}
REPORT_DIR=${3:-$(dirname "$HARNESS")/coverage-report}
PROFRAW_DIR=$(mktemp -d)

NUMPY_COV_SO=$(find /build/numpy-cov -name '_multiarray_umath*.so' | head -1)
if [ -z "$NUMPY_COV_SO" ]; then
    echo "ERROR: could not find coverage-instrumented NumPy .so under /build/numpy-cov"
    exit 1
fi

# /build/numpy-cov first so it shadows the fuzz build in site-packages.
# -S skips site.py so site-packages is never added to sys.path at all.
# We manually include dist-packages so atheris and other deps are still found.
COV_PYTHONPATH="/build/numpy-cov:/usr/local/lib/python3.11/dist-packages:/usr/lib/python3.11:/usr/lib/python3.11/lib-dynload"

echo "==> Coverage .so: $NUMPY_COV_SO"
echo "==> Harness:      $HARNESS"
echo "==> Corpus:       $CORPUS_DIR"
echo "==> Report:       $REPORT_DIR"
echo "==> Profraw tmp:  $PROFRAW_DIR"
echo ""

# ── Verify the right numpy loads ──────────────────────────────────────────────
echo "==> Verifying coverage build loads correctly..."
PYTHONPATH="$COV_PYTHONPATH" \
/usr/bin/python3.11 -S -c "
import numpy
so = numpy._core._multiarray_umath.__file__
expected = '/build/numpy-cov'
if expected in so:
    print('    OK — loading coverage build:', so)
else:
    print('    ERROR — wrong numpy loaded:', so)
    raise SystemExit(1)
"

# ── Write a self-contained replay runner ──────────────────────────────────────
# Rather than going through libFuzzer (which may not write .profraw files
# reliably when given a single file argument), we import the harness module
# directly and call TestOneInput ourselves. This guarantees the coverage
# runtime fires and flushes a .profraw on every clean exit.
RUNNER="$PROFRAW_DIR/runner.py"
cat > "$RUNNER" << 'PYEOF'
import sys
import importlib.util

# Load the harness as a module without executing its atheris.Setup/Fuzz calls.
# We patch atheris.Setup and atheris.Fuzz to no-ops so importing the harness
# only defines TestOneInput without starting the fuzzer.
import atheris
atheris.Setup = lambda *a, **kw: None
atheris.Fuzz  = lambda *a, **kw: None

harness_path = sys.argv[1]
input_path   = sys.argv[2]

spec = importlib.util.spec_from_file_location("harness", harness_path)
mod  = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

data = open(input_path, 'rb').read()
mod.TestOneInput(data)
PYEOF

# ── Step 1: replay each corpus input ─────────────────────────────────────────
echo "==> Replaying corpus inputs..."
count=0
for input in "$CORPUS_DIR"/*; do
    [ -f "$input" ] || continue
    LLVM_PROFILE_FILE="$PROFRAW_DIR/cov-%p.profraw" \
    PYTHONPATH="$COV_PYTHONPATH" \
    /usr/bin/python3.11 -S "$RUNNER" "$HARNESS" "$input"
    count=$((count + 1))
done
echo "    Replayed $count inputs."
echo ""

# Check that .profraw files were actually written
profraw_count=$(ls "$PROFRAW_DIR"/cov-*.profraw 2>/dev/null | wc -l)
echo "==> .profraw files written: $profraw_count"
if [ "$profraw_count" -eq 0 ]; then
    echo "ERROR: no .profraw files found — coverage instrumentation did not fire."
    echo "       Check that the coverage .so has __llvm_covmap sections:"
    echo "       llvm-objdump-14 --section-headers $NUMPY_COV_SO | grep cov"
    exit 1
fi
echo ""

# ── Step 2: merge .profraw files ──────────────────────────────────────────────
echo "==> Merging .profraw files..."
llvm-profdata-14 merge \
    --sparse \
    --output="$PROFRAW_DIR/merged.profdata" \
    "$PROFRAW_DIR"/cov-*.profraw

# ── Step 3: coverage report filtered to round() source ───────────────────────
# The .so embeds source paths rooted at /build/numpy-2.2.5/.mesonpy-XXXXXX/../
# because meson builds from a temporary subdirectory. The tmp dir is cleaned up
# after the pip install so we cannot find it on disk. Instead we extract the
# embedded prefix directly from the .so using strings, then use
# --path-equivalence to remap it to the real source location.
# Extract the embedded meson tmp prefix from llvm-cov's own error output.
# The coverage mapping section stores paths like:
#   /build/numpy-2.2.5/.mesonpy-XXXXXX/../numpy/_core/src/...
# We grab the .mesonpy-XXXXXX/.. portion so we can remap it.
MESON_PREFIX=$(llvm-cov-14 show "$NUMPY_COV_SO" \
    --instr-profile="$PROFRAW_DIR/merged.profdata" \
    --show-line-counts 2>&1 \
    | grep -o '/build/numpy-2\.2\.5/\.mesonpy-[^/]*' \
    | head -1)
if [ -z "$MESON_PREFIX" ]; then
    echo "ERROR: could not extract meson tmp prefix from llvm-cov output"
    exit 1
fi
echo "==> Embedded meson prefix: $MESON_PREFIX"
# Remap $MESON_PREFIX/.. -> /build/numpy-2.2.5
PATH_EQUIV="$MESON_PREFIX/..,/build/numpy-2.2.5"

# methods.c    – contains array_round() and PyArray_Round()
# calculation.c – contains supporting calculation functions called by round
echo ""
echo "==> Coverage report for round() source:"
llvm-cov-14 report \
    "$NUMPY_COV_SO" \
    --instr-profile="$PROFRAW_DIR/merged.profdata" \
    --path-equivalence="$PATH_EQUIV" \
    /build/numpy-2.2.5/numpy/_core/src/multiarray/methods.c \
    /build/numpy-2.2.5/numpy/_core/src/multiarray/calculation.c