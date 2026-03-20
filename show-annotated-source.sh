#!/bin/sh
# show-annotated-source.sh  —  print annotated source for PyArray_Round
#
# Usage:
#   ./show-annotated-source.sh <tmp-suffix>
#
# Example:
#   ./show-annotated-source.sh qkiUlqvnFW

TMP_SUFFIX=${1:?Usage: show-pyarray-round.sh <tmp-suffix>}
PROFDATA="/tmp/tmp.${TMP_SUFFIX}/merged.profdata"
NUMPY_COV_SO=$(find /build/numpy-cov -name '_multiarray_umath*.so' | head -1)

MESON_PREFIX=$(llvm-cov-14 show "$NUMPY_COV_SO" \
    --instr-profile="$PROFDATA" 2>&1 \
    | grep -o '/build/numpy-2\.2\.5/\.mesonpy-[^/]*' \
    | head -1)

llvm-cov-14 show "$NUMPY_COV_SO" \
    --instr-profile="$PROFDATA" \
    --path-equivalence="$MESON_PREFIX/..,/build/numpy-2.2.5" \
    --show-line-counts \
    /build/numpy-2.2.5/numpy/_core/src/multiarray/calculation.c \
    /build/numpy-2.2.5/numpy/_core/src/multiarray/methods.c \
    2>/dev/null | sed -n '/PyArray_Round/,/^[0-9]*|.*^}/p' | head -80