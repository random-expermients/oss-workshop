#!/usr/bin/env bash
# =============================================================================
#  Module 3 — build-oqs.sh : build liboqs + oqs-provider against OpenSSL 3.5
#
#  WHY THIS MODULE EXISTS (read this before deciding to build anything):
#  OpenSSL 3.5 already ships ML-KEM and ML-DSA natively. You do NOT need
#  liboqs for the standardized algorithms — and in fact oqs-provider 0.9.0+
#  *deliberately disables* its own ML-KEM/ML-DSA when it detects OpenSSL 3.5+,
#  deferring to the native implementations.
#
#  So liboqs/oqs-provider is NOT an alternative route to ML-KEM. Its job in
#  2026 is ALGORITHM EVALUATION: trying schemes that are not standardized,
#  not yet in native OpenSSL, or kept for algorithm diversity / research —
#  HQC, BIKE, FrodoKEM (KEMs); SLH-DSA, FN-DSA/Falcon, SNOVA, LMS (sigs).
#  That is the honest reason a provider plugin still matters.
#
#  This script builds both and prints the verification commands. It targets
#  Fedora (dnf). Building from source is the realistic path because distro
#  packages for oqs-provider lag and you usually want a specific liboqs build.
#
#  STRONGLY consider running this in the provided container (Containerfile)
#  instead of on your host — it compiles C, installs a provider into your
#  OpenSSL tree, and you probably don't want that on your daily-driver desktop.
# =============================================================================
set -euo pipefail

PREFIX="${PREFIX:-$HOME/oqs-local}"     # where liboqs is installed
JOBS="${JOBS:-$(nproc)}"
LIBOQS_REF="${LIBOQS_REF:-main}"        # pin a tag for reproducibility in a real workshop
OQSPROV_REF="${OQSPROV_REF:-main}"

# ---- version guard: oqs-provider's "defer to native" behavior needs 3.5+ ---
ver=$(openssl version | awk '{print $2}')
case "$ver" in
  3.5*|3.6*|3.7*|3.8*|3.9*) : ;;
  *) echo "WARNING: OpenSSL $ver detected. This module's teaching point" >&2
     echo "         (oqs-provider deferring ML-KEM/ML-DSA to native) only" >&2
     echo "         holds on OpenSSL 3.5+. On older OpenSSL, oqs-provider" >&2
     echo "         supplies ML-KEM/ML-DSA itself. Proceeding anyway." >&2 ;;
esac

echo "==> Installing build dependencies (Fedora)"
sudo dnf -y install gcc gcc-c++ cmake ninja-build git \
     openssl openssl-devel python3 python3-pytest

echo "==> [1/3] building liboqs (with HQC explicitly enabled)"
# HQC is disabled by default in liboqs; we turn it on because it's one of the
# most interesting things to *evaluate* (a code-based KEM, NIST-selected 2025).
rm -rf /tmp/liboqs && git clone --depth 1 --branch "$LIBOQS_REF" \
     https://github.com/open-quantum-safe/liboqs /tmp/liboqs
cmake -S /tmp/liboqs -B /tmp/liboqs/build -GNinja \
     -DCMAKE_INSTALL_PREFIX="$PREFIX" \
     -DOQS_ENABLE_KEM_HQC=ON \
     -DBUILD_SHARED_LIBS=ON
ninja -C /tmp/liboqs/build -j"$JOBS"
ninja -C /tmp/liboqs/build install

echo "==> [2/3] building oqs-provider against this liboqs"
rm -rf /tmp/oqs-provider && git clone --depth 1 --branch "$OQSPROV_REF" \
     https://github.com/open-quantum-safe/oqs-provider /tmp/oqs-provider
cmake -S /tmp/oqs-provider -B /tmp/oqs-provider/build -GNinja \
     -DCMAKE_PREFIX_PATH="$PREFIX" \
     -Dliboqs_DIR="$PREFIX/lib64/cmake/liboqs"
ninja -C /tmp/oqs-provider/build -j"$JOBS"

# The built provider module:
PROV_SO=$(find /tmp/oqs-provider/build -name 'oqsprovider.so' | head -1)
echo "==> [3/3] built provider: $PROV_SO"

echo
echo "============================================================"
echo "  HOW TO LOAD IT (without touching openssl.cnf)"
echo "============================================================"
cat <<EOF
  export OPENSSL_MODULES=$(dirname "$PROV_SO")
  export LD_LIBRARY_PATH=$PREFIX/lib64:\${LD_LIBRARY_PATH:-}

  # then, on any openssl command, add:  -provider oqsprovider -provider default

  Verify both providers load:
    openssl list -providers -provider oqsprovider -provider default

  See what oqs-provider ADDS (note ML-KEM/ML-DSA will NOT appear here on
  OpenSSL 3.5+ — they're disabled in favor of native; that's the lesson):
    openssl list -kem-algorithms       -provider oqsprovider | grep -i oqs
    openssl list -signature-algorithms -provider oqsprovider | grep -i oqs
EOF
echo
echo "==> Now run ./evaluate.sh to walk through the provider concepts."
