#!/usr/bin/env bash
# =============================================================================
#  Module 3 — evaluate.sh : the OpenSSL provider concept, made concrete,
#  and a worked example of EVALUATING a non-standardized algorithm via liboqs.
#
#  Run AFTER build-oqs.sh, with the provider on the module path:
#     export OPENSSL_MODULES=<dir containing oqsprovider.so>
#     export LD_LIBRARY_PATH=$HOME/oqs-local/lib64:$LD_LIBRARY_PATH
#     ./evaluate.sh
#
#  Or run the whole thing in the container (see Containerfile / README).
#
#  Structure follows the concepts in order:
#     1. What IS a provider?                (list providers, see @default tags)
#     2. Loading a second provider          (oqsprovider alongside default)
#     3. Native vs plugin: who supplies what (the deferral lesson)
#     4. Evaluate a candidate KEM (HQC):    keygen, encaps, speed
#     5. Evaluate it IN A TLS HANDSHAKE     (hybrid group via oqs-provider)
#     6. How you'd benchmark for a real eval
# =============================================================================
set -uo pipefail   # NOTE: not -e; we want to show commands even if one fails

OQS="-provider oqsprovider -provider default"   # load order: try oqs first
WORK="${WORK:-./oqs-eval}"
mkdir -p "$WORK"; cd "$WORK"

line(){ echo; echo "============================================================"; echo "  $*"; echo "============================================================"; }

# ---------------------------------------------------------------------------
line "1. What is a provider?  (a pluggable crypto backend)"
cat <<'TXT'
A "provider" in OpenSSL 3 is a module that supplies algorithm
implementations. OpenSSL ships:
  - default   : the normal algorithms (incl. native ML-KEM/ML-DSA on 3.5+)
  - fips      : the FIPS-validated subset
  - legacy    : old algorithms (MD2, RC4, ...)
Every algorithm is tagged with the provider that supplies it. Watch for the
"@ default" / "@ oqsprovider" suffix in the listings below — that tag IS the
concept: it tells you which backend answers for each algorithm.
TXT
echo "--- providers active by default: ---"
openssl list -providers

# ---------------------------------------------------------------------------
line "2. Loading a second provider (oqsprovider) alongside default"
echo "--- both providers, loaded explicitly on the command line: ---"
openssl list -providers $OQS
echo
echo "(If oqsprovider is missing here, OPENSSL_MODULES isn't pointing at"
echo " oqsprovider.so. Re-check the exports from build-oqs.sh.)"

# ---------------------------------------------------------------------------
line "3. Native vs plugin — who supplies what (the key lesson)"
echo "--- KEMs the oqs-provider exposes (grep for the oqs tag): ---"
openssl list -kem-algorithms $OQS | grep -iE 'hqc|bike|frodo|mlkem|ml-kem' || true
echo
cat <<'TXT'
On OpenSSL 3.5+ you will typically NOT see ML-KEM listed under oqsprovider:
oqs-provider 0.9.0+ disables its own ML-KEM/ML-DSA when native support is
present, to avoid two implementations fighting. So the standardized
algorithms come from `default` (native), and oqs-provider's real value is
the EVALUATION-stage algorithms: HQC, BIKE, FrodoKEM, and the alternate
signatures. That division is the whole point of this module.
TXT

# ---------------------------------------------------------------------------
line "4. Evaluate a candidate KEM: HQC (code-based, NIST-selected 2025)"
echo "HQC is not in native OpenSSL and is disabled by default even in liboqs"
echo "(we enabled it in build-oqs.sh). This is exactly the 'try a new algo'"
echo "scenario. First, confirm it's available:"
openssl list -kem-algorithms $OQS | grep -i hqc || \
  echo "  (HQC not found — rebuild liboqs with -DOQS_ENABLE_KEM_HQC=ON)"

echo
echo "--- generate an HQC keypair via the provider (genpkey): ---"
# Algorithm names follow oqs-provider's naming; hqc128/192/256 are typical.
HQC_ALG="$(openssl list -kem-algorithms $OQS | grep -ioE 'hqc[0-9]+' | head -1)"
if [ -n "${HQC_ALG:-}" ]; then
  echo "    using algorithm: $HQC_ALG"
  openssl genpkey -algorithm "$HQC_ALG" $OQS -out hqc.key 2>/dev/null \
    && echo "    -> wrote hqc.key ($(wc -c < hqc.key) bytes)" \
    || echo "    (genpkey for $HQC_ALG not supported in this build; that's a"
  echo "     legitimate evaluation finding to report, not a script bug)"
else
  echo "    HQC unavailable; skipping keygen."
fi

# ---------------------------------------------------------------------------
line "5. Evaluate a candidate in a TLS 1.3 handshake (hybrid group)"
cat <<'TXT'
oqs-provider also registers hybrid TLS groups so you can put a candidate
through a real handshake. Example, IF your build exposes it:

  # terminal A — server offering an oqs hybrid group:
  openssl s_server -accept 4433 -tls1_3 \
      -provider oqsprovider -provider default \
      -groups p256_frodo640aes \
      -cert server.crt -key server.key -www

  # terminal B — client requesting the same group:
  openssl s_client -connect localhost:4433 -tls1_3 \
      -provider oqsprovider -provider default \
      -groups p256_frodo640aes </dev/null 2>&1 | grep -i 'group\|temp key'

The teaching beat: the SAME `openssl s_server` binary speaks a brand-new
key-exchange scheme purely because a provider was loaded. No recompiled
openssl, no patched TLS stack. That is the provider architecture paying off.
TXT
echo "--- hybrid groups this build advertises: ---"
openssl list -kem-algorithms $OQS | grep -iE 'p256_|x25519_|p384_' | head -10 || \
  echo "  (no classic-hybrid groups found in this build)"

# ---------------------------------------------------------------------------
line "6. How you'd actually benchmark for an evaluation"
cat <<'TXT'
A real algorithm evaluation compares, at minimum:
  * key sizes        (public key, private key)
  * ciphertext/sig sizes  (what goes on the wire — the TLS cost)
  * speed            (keygen / encaps-decaps or sign-verify ops per second)
  * security level   (NIST level 1/3/5)

liboqs ships a speed harness built from the same source you compiled:
    $HOME/oqs-local/bin/... or /tmp/liboqs/build/tests/speed_kem
    /tmp/liboqs/build/tests/speed_sig
Run those to get apples-to-apples numbers across HQC / BIKE / FrodoKEM /
ML-KEM. Report SIZES alongside SPEED — the headline tradeoff for the
code-based KEMs (HQC, BIKE) is large keys/ciphertexts, which is precisely
the kind of cost a TLS-focused evaluation needs to surface.
TXT

echo
echo "==> End of provider walkthrough. See README for how this ties back to"
echo "    Modules 1-2 (native, standardized) vs evaluation (this module)."
