#!/usr/bin/env bash
# =============================================================================
#  Module 3 — evaluate.sh : the OpenSSL provider concept, made concrete,
#  and a worked, DEMONSTRABLE example of evaluating non-standardized
#  algorithms via liboqs:
#       KEM       -> FrodoKEM (or BIKE)   — conservative / code-based candidates
#       SIGNATURE -> SLH-DSA  (SPHINCS+)  — hash-based standardized signature
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
#     4. Evaluate a candidate KEM           (FrodoKEM/BIKE: keygen + pub key)
#     5. Evaluate a candidate SIGNATURE     (SLH-DSA: keygen + sign + verify)
#     6. Put them together in a TLS 1.3 handshake (Frodo group + SLH-DSA cert)
#     7. How you'd benchmark for a real eval
# =============================================================================
set -uo pipefail   # NOTE: not -e; we want to show commands even if one fails

OQS="-provider oqsprovider -provider default"   # load order: try oqs first
WORK="${WORK:-./oqs-eval}"
mkdir -p "$WORK"; cd "$WORK"

line(){ echo; echo "============================================================"; echo "  $*"; echo "============================================================"; }

# Pick the first algorithm whose name matches a regex, from a given list type.
pick_alg(){ # $1 = list type (kem|signature) ; $2 = grep -E regex
  openssl list "-$1-algorithms" $OQS 2>/dev/null \
    | grep -ioE "$2" | head -1
}

# Locate a liboqs speed harness (built by build-oqs.sh / the Containerfile).
find_harness(){ # $1 = binary name (speed_kem|speed_sig)
  local p
  for p in "/src/liboqs/build/tests/$1" \
           "/tmp/liboqs/build/tests/$1" \
           "$HOME/liboqs/build/tests/$1" \
           "$HOME/oqs-local/bin/$1"; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  command -v "$1" 2>/dev/null && return 0
  return 1
}

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
echo "--- KEMs the oqs-provider exposes: ---"
openssl list -kem-algorithms $OQS | grep -iE 'hqc|bike|frodo|mlkem|ml-kem' || true
echo
echo "--- alternate SIGNATURES the oqs-provider exposes: ---"
openssl list -signature-algorithms $OQS | grep -iE 'slh|sphincs|falcon|mayo|dilithium' || true
echo
cat <<'TXT'
On OpenSSL 3.5+ the STANDARDIZED algorithms (ML-KEM, ML-DSA) come from
`default` (native), and oqs-provider stays out of the way for those. Its real
value is the EVALUATION-stage algorithms:
  * KEMs:        FrodoKEM, BIKE, HQC   (conservative / code-based candidates)
  * Signatures:  SLH-DSA (SPHINCS+), Falcon, MAYO ...
This module evaluates one of each: a FrodoKEM/BIKE KEM and an SLH-DSA signature.
TXT

# ---------------------------------------------------------------------------
line "4. Evaluate a candidate KEM: FrodoKEM (fallback: BIKE)"
cat <<'TXT'
FrodoKEM is a conservative, lattice-based KEM (no algebraic ring structure —
the deliberately "boring" safe choice). BIKE is the code-based alternative.
Neither is in native OpenSSL, so this is exactly the "try a new algo"
scenario the provider architecture exists for.
TXT
echo "--- (a) confirm the candidate is exposed by the provider: ---"
KEM_ALG="$(pick_alg kem 'frodo[a-z0-9]+')"
if [ -z "${KEM_ALG:-}" ]; then
  echo "    FrodoKEM not found; falling back to BIKE..."
  KEM_ALG="$(pick_alg kem 'bike[a-z0-9]*')"
fi
[ -n "${KEM_ALG:-}" ] \
  && echo "    provider advertises KEM: $KEM_ALG (used in the handshake below)" \
  || echo "    no FrodoKEM/BIKE in provider — rebuild liboqs with those enabled."

cat <<'TXT'

    Note: oqs-provider KEM keys have no standard PEM/DER encoder, so a bare
    `openssl genpkey -out file` can't serialize them (a real evaluation
    finding, not a bug). A KEM is meant to be exercised by encaps/decaps, so
    we demonstrate it two honest ways:
      (b) the liboqs speed harness — real keygen + encaps + decaps + sizes
      (6) a real TLS 1.3 handshake using the FrodoKEM hybrid group
TXT
echo "--- (b) real keygen/encaps/decaps + sizes via the liboqs harness: ---"
SPEED_KEM="$(find_harness speed_kem || true)"
if [ -n "${SPEED_KEM:-}" ]; then
  # Map to a liboqs algorithm name (FrodoKEM-* / BIKE-*); prefer FrodoKEM.
  KEM_BENCH="$("$SPEED_KEM" --algs 2>/dev/null | grep -iE '^FrodoKEM-' | head -1)"
  [ -z "${KEM_BENCH:-}" ] && KEM_BENCH="$("$SPEED_KEM" --algs 2>/dev/null | grep -iE '^BIKE-' | head -1)"
  if [ -n "${KEM_BENCH:-}" ]; then
    echo "    benchmarking $KEM_BENCH (1s/op); watch the 'public key/ciphertext bytes':"
    "$SPEED_KEM" -i -d 1 "$KEM_BENCH" 2>/dev/null \
      | grep -iE "$KEM_BENCH|keygen|encaps|decaps|public key bytes" \
      || echo "    (harness ran but produced no rows; see build logs)"
    echo
    echo "    The headline finding: FrodoKEM/BIKE public keys and ciphertexts are"
    echo "    KILOBYTES (vs ~0.8 KB for ML-KEM-512) — the on-the-wire cost a"
    echo "    TLS-focused evaluation must surface."
  else
    echo "    (harness present but lists no FrodoKEM/BIKE algorithm)"
  fi
else
  echo "    (liboqs speed_kem not found; the TLS handshake in step 6 still"
  echo "     demonstrates the KEM end-to-end)"
fi

# ---------------------------------------------------------------------------
line "5. Evaluate a candidate SIGNATURE: SLH-DSA (SPHINCS+)"
cat <<'TXT'
SLH-DSA is the hash-based signature standard (FIPS 205). It trades large,
slow signatures for security resting only on hash functions — the most
conservative PQC assumption. We do a real keygen + sign + verify.
TXT
echo "--- searching for an SLH-DSA / SPHINCS+ signature in this build: ---"
# Prefer a native SLH-DSA name (OpenSSL 3.5+), else the oqs SPHINCS+ name.
SIG_ALG="$(pick_alg signature 'slh-dsa-sha2-128s')"
[ -z "${SIG_ALG:-}" ] && SIG_ALG="$(pick_alg signature 'slh-dsa[a-z0-9-]+')"
[ -z "${SIG_ALG:-}" ] && SIG_ALG="$(pick_alg signature 'sphincs[a-z0-9]+')"

if [ -n "${SIG_ALG:-}" ]; then
  echo "    using SIGNATURE algorithm: $SIG_ALG"
  echo
  echo "--- (a) generate an SLH-DSA keypair: ---"
  if openssl genpkey -algorithm "$SIG_ALG" $OQS -out slh.key 2>/dev/null; then
    echo "    -> wrote slh.key ($(wc -c < slh.key) bytes)"
    echo "the quick brown fox jumps over the lazy dog" > msg.txt
    echo
    echo "--- (b) SIGN a message with the private key: ---"
    if openssl pkeyutl -sign -inkey slh.key $OQS -rawin -in msg.txt -out msg.sig 2>/dev/null; then
      echo "    -> wrote msg.sig ($(wc -c < msg.sig) bytes — note how LARGE an"
      echo "       SLH-DSA signature is; that is its defining tradeoff)"
      echo
      echo "--- (c) VERIFY the signature with the public key: ---"
      openssl pkey -in slh.key $OQS -pubout -out slh.pub 2>/dev/null
      if openssl pkeyutl -verify -pubin -inkey slh.pub $OQS -rawin -in msg.txt -sigfile msg.sig 2>/dev/null; then
        echo "    -> VERIFY OK : signature is valid. Demonstration complete."
      else
        echo "    -> verify failed (report as an evaluation finding)"
      fi
    else
      echo "    (sign for $SIG_ALG not supported in this build)"
    fi
  else
    echo "    (genpkey for $SIG_ALG not supported in this build)"
  fi
else
  echo "    SLH-DSA / SPHINCS+ not found. Enable it in build-oqs.sh"
  echo "    (-DOQS_ENABLE_SIG_SPHINCS=ON) or use OpenSSL 3.5+ native SLH-DSA."
fi

# ---------------------------------------------------------------------------
line "6. Put it together: a REAL TLS 1.3 handshake over the FrodoKEM group"
cat <<'TXT'
Now the payoff: the SAME openssl s_server/s_client binaries speak a brand-new
KEM for key exchange, purely because a provider was loaded. No recompiled
openssl, no patched TLS stack. We run server + client locally and confirm the
negotiated group.

About the certificate: SLH-DSA is a perfectly good signature (we just signed
and verified with it in step 5), but OpenSSL 3.5's TLS stack does NOT yet
accept SLH-DSA certificates for handshake authentication — itself a useful
evaluation finding. So we authenticate with ML-DSA (also post-quantum), giving
a fully-PQC handshake: FrodoKEM key exchange + ML-DSA signature.
TXT

# Find a classic-hybrid Frodo TLS group (these are what s_server/s_client speak).
TLS_GROUP="$(openssl list -kem-algorithms $OQS 2>/dev/null \
  | grep -ioE '(p256|x25519|p384)_frodo[a-z0-9]+' | head -1)"
[ -z "${TLS_GROUP:-}" ] && TLS_GROUP="$(openssl list -kem-algorithms $OQS 2>/dev/null \
  | grep -ioE '(p256|x25519|p384|p521|x448)_bike[a-z0-9]*' | head -1)"

# Native ML-DSA for certificate authentication.
CERT_SIG="$(pick_alg signature 'ml-dsa-65')"
[ -z "${CERT_SIG:-}" ] && CERT_SIG="$(pick_alg signature 'ml-dsa-[0-9]+')"
[ -z "${CERT_SIG:-}" ] && CERT_SIG="$(pick_alg signature 'mldsa[0-9]+')"

if [ -n "${TLS_GROUP:-}" ] && [ -n "${CERT_SIG:-}" ]; then
  echo "    TLS key-exchange group : $TLS_GROUP   (FrodoKEM/BIKE — the candidate)"
  echo "    certificate signature  : $CERT_SIG   (ML-DSA — PQC authentication)"
  echo
  echo "--- (a) optional finding: confirm SLH-DSA is rejected by the TLS stack ---"
  if [ -n "${SIG_ALG:-}" ] \
     && openssl req -x509 -new -newkey "$SIG_ALG" -keyout slh-srv.key -out slh-srv.crt \
          -nodes -subj "/CN=pqc-demo.local" -days 1 $OQS >/dev/null 2>&1; then
    openssl s_server -accept 4432 -tls1_3 $OQS -groups "$TLS_GROUP" \
        -cert slh-srv.crt -key slh-srv.key -www >slh.log 2>&1 &
    SLH_PID=$!; sleep 1
    if grep -qi 'error setting certificate\|unknown certificate type' slh.log 2>/dev/null; then
      echo "    -> confirmed: OpenSSL 3.5 TLS refuses an SLH-DSA server cert"
      echo "       ($(grep -i error slh.log | head -1 | sed 's/^.*:error:/error:/'))"
    else
      echo "    -> SLH-DSA cert was accepted by this build (newer than expected)"
    fi
    kill "$SLH_PID" 2>/dev/null; wait "$SLH_PID" 2>/dev/null
  else
    echo "    (skipped — no SLH-DSA available to test)"
  fi
  echo
  echo "--- (b) make a self-signed ML-DSA server certificate: ---"
  if openssl req -x509 -new -newkey "$CERT_SIG" -keyout server.key -out server.crt \
        -nodes -subj "/CN=pqc-demo.local" -days 1 $OQS 2>/dev/null; then
    echo "    -> server.crt + server.key (signed with $CERT_SIG)"
    echo
    echo "--- (c) start s_server in the background on :4433: ---"
    openssl s_server -accept 4433 -tls1_3 $OQS \
        -groups "$TLS_GROUP" \
        -cert server.crt -key server.key -www >server.log 2>&1 &
    SRV_PID=$!
    # wait for the listener to accept connections (no blind sleep)
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$SRV_PID" 2>/dev/null || break
      (exec 3<>/dev/tcp/127.0.0.1/4433) 2>/dev/null && { exec 3>&- 3<&-; break; }
      sleep 0.3
    done
    echo
    echo "--- (d) connect with s_client and capture the negotiated params: ---"
    if openssl s_client -connect 127.0.0.1:4433 -tls1_3 $OQS \
          -groups "$TLS_GROUP" </dev/null 2>&1 \
          | grep -iE 'Negotiated TLS1.3 group|Peer signature type|Cipher is' ; then
      echo "    -> handshake completed: $TLS_GROUP key exchange + $CERT_SIG auth."
      echo "       That FrodoKEM key exchange ran in stock openssl, unmodified,"
      echo "       purely because oqs-provider was loaded. That is the payoff."
    else
      echo "    -> handshake did not report group/sig; see server.log."
    fi
    kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null
  else
    echo "    (could not create ML-DSA cert in this build; skipping handshake)"
  fi
else
  echo "    Missing a Frodo/BIKE TLS group or an ML-DSA signature in this"
  echo "    build, so the combined handshake can't be demonstrated here."
  echo "    Hybrid groups advertised:"
  openssl list -kem-algorithms $OQS | grep -iE 'p256_|x25519_|p384_' | head -10 \
    || echo "      (none found)"
fi

# ---------------------------------------------------------------------------
line "7. How you'd actually benchmark for an evaluation"
cat <<'TXT'
A real algorithm evaluation compares, at minimum:
  * key sizes        (public key, private key)
  * ciphertext/sig sizes  (what goes on the wire — the TLS cost)
  * speed            (keygen / encaps-decaps or sign-verify ops per second)
  * security level   (NIST level 1/3/5)

Step 4 already ran the KEM harness. For signatures, run the matching one to
quantify SLH-DSA's large/slow signatures:
TXT
SPEED_SIG="$(find_harness speed_sig || true)"
if [ -n "${SPEED_SIG:-}" ]; then
  SIG_BENCH="$("$SPEED_SIG" --algs 2>/dev/null | grep -iE 'SLH_DSA|SPHINCS' | head -1)"
  if [ -n "${SIG_BENCH:-}" ]; then
    echo "    $SPEED_SIG -i -d 1 $SIG_BENCH"
    "$SPEED_SIG" -i -d 1 "$SIG_BENCH" 2>/dev/null \
      | grep -iE "$SIG_BENCH|keygen|sign|verify|signature bytes" | head -8 \
      || echo "    (harness produced no rows)"
  else
    echo "    (speed_sig present but lists no SLH-DSA/SPHINCS+ algorithm)"
  fi
else
  echo "    liboqs speed_sig not found on this system; on the container it is at"
  echo "    /src/liboqs/build/tests/speed_sig"
fi
cat <<'TXT'

Report SIZES alongside SPEED: the headline tradeoffs are FrodoKEM/BIKE's large
keys/ciphertexts and SLH-DSA's large, slow signatures — exactly the costs a
TLS-focused evaluation needs to surface.
TXT

echo
echo "==> End of provider walkthrough. See README for how this ties back to"
echo "    Modules 1-2 (native, standardized) vs evaluation (this module)."
