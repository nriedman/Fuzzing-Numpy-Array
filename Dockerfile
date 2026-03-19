FROM ubuntu:jammy

# -----------------------------
# 1. System dependencies
# -----------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    clang \
    llvm \
    build-essential \
    python3-dev \
    python3-pip \
    git \
    vim \
    curl \
    ca-certificates \
    meson \
    ninja-build \
    libblas-dev \
    liblapack-dev \
    gfortran \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------
# 2. Upgrade pip / Python tools
# -----------------------------
RUN pip3 install --upgrade pip setuptools wheel
RUN pip3 install sympy

# -----------------------------
# 3. Environment for libFuzzer / Atheris
# -----------------------------
ENV LIBFUZZER_LIB="/usr/lib/llvm-14/lib/clang/14.0.0/lib/linux/libclang_rt.fuzzer-aarch64.a"

# -----------------------------
# 4. Force Clang for builds
# -----------------------------
ENV CC=clang
ENV CXX=clang++

# -----------------------------
# 5. ASAN + libFuzzer coverage flags (no UBSan)
# -----------------------------
ENV CFLAGS="-O1 -fno-omit-frame-pointer -fsanitize=address -fsanitize-coverage=trace-pc-guard"
ENV CXXFLAGS="$CFLAGS"
ENV LDFLAGS="-fsanitize=address"

# ASAN runtime config
ENV ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:halt_on_error=1

# -----------------------------
# 6. Build NumPy from source
# -----------------------------
ENV PIP_NO_BINARY=numpy
RUN pip3 install numpy==2.2.5

# -----------------------------
# 7. Install Atheris <3.0.0
# -----------------------------
RUN pip3 install "atheris<3.0.0"

# -----------------------------
# 8. Workspace
# -----------------------------
RUN mkdir -p /home/student
WORKDIR /home/student