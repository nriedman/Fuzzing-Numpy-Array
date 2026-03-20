# Fuzzing NumPy Round

Atheris fuzzer for `numpy.round` / `PyArray_Round`, targeting NumPy 2.2.5.
NumPy is compiled from source with ASAN and libFuzzer instrumentation so that
crashes inside the C extension are detected and attributed to specific source lines.

A second coverage-instrumented build of NumPy is also produced, which can be
used to generate line/region/branch coverage reports over a fuzzer corpus.

---

## Prerequisites

- Docker

---

## Setup

### 1. Clone the repository

```bash
git clone https://github.com/nriedman/Fuzzing-Numpy-Array.git
cd FuzzingNumpyArray
```

### 2. Build and Run the Docker container

This compiles NumPy 2.2.5 twice from source — once with ASAN + libFuzzer
instrumentation for fuzzing, and once with LLVM source-based coverage
instrumentation for coverage reporting. Expect the build to take minutes.

```bash
./run_docker.sh
```

The start script will also mount the repository into the container so
that your harness and corpus are accessible from both the host and the
container, and changes to the harness don't require a rebuild.

If there is a permissions error, fix it with:

```bash
chmod +x run_docker.sh
```

This is true for all `.sh` files in this repository.

---

## Fuzzing

We iterated on three fuzzer harnesses to explore the effect that manually
exposeing libFuzzer coverage hooks in the NumPy C code has on Atheris' ability
to get high coverage on these files.

All commands below are run **inside the container**. Note that we require
`python3.11` **specifically**, as this is the interpreter the Docker sets up
to hook onto the libFuzzed NumPy build.

For all examples, to stop after a fixed number of executions:

```bash
python3.11 <harness> <corpus> -runs=100000
```

Crash reproducer inputs are saved to the current directory as `crash-<hash>`.

### 1. Reproducing the crash

```bash
python3.11 fuzz-round.py corpus/
```

`fuzz-round.py` contains a fuzz harness that, when we test the system, instantly
triggers the segmentation fault. Even passing `-ignore_crashes=1` to atheris
does not allow the program to continue. This could be a consequence of our manual
compilation of NumPy. Because of this behavior, we were unable to evaluate code
coverage.

### 2. Source-blind exploration

```bash
python3.11 fuzz-round-v1.py corpus-v1/
```

`fuzz-round-v1.py` contains a fuzz harness that attempts to achieve higher coverage,
without worrying about isolating the crash. We were interested in observing Atheris'
ability to see the C Extension source code, and fuzz based on the coverage that, without
our manual compilation of NumPy, it would otherwise be blind to.

This fuzzer ended up being too simplistic, and we were only able to cover a single
execution path through the C source code. We call this "source-blind" because we did
not implement the test harness to specifically target paths in the source code.

Using this fuzzer, we reached the following code coverage (`N = 1` inputs):

#### File-level coverage (round-related source)
 
| File | Regions | Region Cover | Lines | Line Cover | Branches | Branch Cover |
|---|---|---|---|---|---|---|
| `methods.c` | 2086 | 1.25% | 2078 | 1.78% | 812 | 0.99% |
| `calculation.c` | 667 | 10.04% | 669 | 7.62% | 244 | 8.20% |
| **Total** | **2753** | **3.38%** | **2747** | **3.20%** | **1056** | **2.65%** |
 
#### Function-level coverage

| Function | File | Region Coverage |
|---|---|---|
| `PyArray_Round` | `methods.c` | 103/318 (32%) |

### 3. Source-aware exploration

```bash
python3.11 fuzz-round-v2.py corpus-v2/
```

Finally, after investigating the source code coverage from our previous test harenesses,
we extended the test harness to more readily expose options to the fuzzer that we know will
reach more control blocks.

Using this fuzzer, we reached the following code coverage (`N = 6` inputs):

#### File-level coverage (round-related source)
 
| File | Regions | Region Cover | Lines | Line Cover | Branches | Branch Cover |
|---|---|---|---|---|---|---|
| `methods.c` | 2086 | 1.25% | 2078 | 1.78% | 812 | 0.99% |
| `calculation.c` | 667 | 12.74% | 669 | 10.01% | 244 | 10.66% |
| **Total** | **2753** | **4.03%** | **2747** | **3.79%** | **1056** | **3.22%** |
 
#### Function-level coverage
 
| Function | File | Region Coverage |
|---|---|---|
| `PyArray_Round` | `methods.c` | 136/318 (42%) |

---

## Coverage Reporting

After fuzzing has built up a corpus, replay it through the coverage-instrumented
NumPy build to produce a report showing which lines of `PyArray_Round` and
surrounding code were reached. For example:

```bash
./run-coverage-report.sh fuzz-round-v2.py corpus-v2/
```

The script prints a per-file summary table to the terminal showing line, region,
and branch coverage for `calculation.c` (which contains `PyArray_Round`) and
`methods.c` (which contains wrappers invoked by `numpy.round`).

Ideally, crashing inputs would be noted in the output but wouldn't abort the replay —
coverage up to the crash point would still be recorded. However, this did not
end up working in our case, possibly related to the unavoidable crash in the first
fuzzer.

An additional utility script can be used to print the annotated source code
from the most recent coverage report:

```bash
./show-annotated-source.sh <tmp_code>
```

where `tmp_code` is the random name of the temporary file created by the last
coverage report. The name is printed to the terminal, and may look something like:

```
==> Profraw tmp:  /tmp/tmp.cjaXOvYP09
```

In this case, the command to show annotated source code would be:

```bash
./show-annotated-source.sh cjaXOvYP09
```

---

## Files

| File | Description |
|---|---|
| `Dockerfile` | Builds the fuzzing environment with two NumPy builds |
| `run_docker.sh` | Convenience script to build and run the container |
| `fuzz-round*.py` | Atheris fuzz harnesses targeting `np.round` |
| `run-coverage-report.sh` | Replays a corpus and prints a coverage summary |
| `show-annotated-source.sh` | Prints the most recent annotated source code |

---

## Known Bugs Found

### `PyArray_Round` segfault on `decimals=INT_MIN`

Calling `np.round(arr, -2147483648)` on any float array triggers an
out-of-bounds memory read inside `PyArray_Round` in
`numpy/_core/src/multiarray/calculation.c`. The `decimals` parameter is used
to compute a power-of-ten scaling factor, and `INT_MIN` causes an integer
overflow before the bounds check.

We were not the original reproducers of this bug. More information can be found in the original report [here](https://huntr.com/bounties/49928a2c-c6bb-4c1c-80ec-5d7bf708bf28).

**Reproducer:**

```python
import numpy as np
arr = np.array([1.5])
np.round(arr, -2147483648)  # segfault
```