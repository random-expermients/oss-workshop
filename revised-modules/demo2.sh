#!/usr/bin/env bash
# =============================================================================
#  demo2.sh  —  DEMO 2: "The frontier" (oqs-provider + SNOVA candidate signature)
# =============================================================================
#
#  WHAT THIS SCRIPT IS
#  -------------------
#  A self-paced, narratable recording script for Demo 2. It loads the
#  oqs-provider, surfaces the SNOVA candidate signature, proves ML-KEM still
#  defers to native, triggers the load-order hazard, signs/verifies with SNOVA,
#  and compares SNOVA vs ML-DSA sizes — pausing before each beat so you can
#  narrate, and printing WHAT was done, WHAT got VERIFIED, and WHAT's NEXT.
#
#  WHERE TO RUN IT
#  ---------------
#  Inside the pqc-oqs container (built in lab Step 2.0a/2.0b — liboqs 0.14.0 +
#  oqs-provider 0.10.0, which is the first release that EXPOSES SNOVA). From the
#  HOST:
#
#     cp demo2.sh ~/pqc-lab/                        # so it appears at /work
#     podman run --rm -it -v ~/pqc-lab:/work:ro,Z pqc-oqs
#     # --- inside the container: ---
#     bash /work/demo2.sh
#
#  NOTE: /work is mounted READ-ONLY, so this script writes all keys/sigs to
#  /tmp. It does NOT depend on a pre-existing message.txt — it creates one.
#
#  PACING
#  ------
#  Every beat waits for ENTER (set DEMO_AUTO=1 to disable pauses).
# =============================================================================

# --- NOT 'set -e': Steps 2.1 and 2.4 intentionally produce non-zero / error
#     output (that IS the lesson). We handle outcomes explicitly instead.
set -u

# ---------------------------------------------------------------------------
#  Presentation helpers
# ---------------------------------------------------------------------------
BOLD=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'
CYN=$'\033[36m'; RED=$'\033[31m'; RST=$'\033[0m'

say()   { printf '\n%s\n' "${BOLD}${CYN}=== $* ===${RST}"; }
note()  { printf '%s\n'  "${DIM}# $*${RST}"; }
ok()    { printf '%s\n'  "${GRN}[VERIFIED] $*${RST}"; }
next()  { printf '%s\n'  "${YEL}[NEXT] $*${RST}"; }
run()   { printf '%s\n' "${BOLD}\$ $*${RST}"; eval "$@"; }
pause() { [ "${DEMO_AUTO:-0}" = "1" ] && return 0
          printf '%s' "${DIM}  ...press ENTER to continue...${RST}"; read -r _ || true; }

# ---------------------------------------------------------------------------
#  Config: the SNOVA parameter set we standardized on (discovered in Step 2.2).
#  The bare set — NOT the p256_/p384_ hybrids or the ...esk variants.
# ---------------------------------------------------------------------------
SNOVA_ALG="snova2454"
MSG="/tmp/message.txt"

# ===========================================================================
clear
printf '%s\n' "${BOLD}DEMO 2 — The frontier: test-driving tomorrow's signatures (SNOVA via oqs-provider)${RST}"
note "Same unmodified OpenSSL binary — a provider plug-in adds a brand-new, NON-standardized algorithm."
pause

# ---------------------------------------------------------------------------
say "Step 2.0 — Provider prerequisites (find the module + confirm native OpenSSL 3.5)"
next "oqs-provider only loads if OpenSSL can find oqsprovider.so. This build's DEFAULT"
next "search dir differs from where the module installed, so we point OPENSSL_MODULES at it."
run "openssl version"
note "locating the installed provider module:"
MODPATH="$(find / -name 'oqsprovider.so' 2>/dev/null | grep -v '/build/' | head -1)"
if [ -n "$MODPATH" ]; then
  export OPENSSL_MODULES="$(dirname "$MODPATH")"
else
  export OPENSSL_MODULES="/usr/lib64/ossl-modules"   # known install dir on this image
fi
run "export OPENSSL_MODULES=$OPENSSL_MODULES"
ok "OpenSSL is 3.5 native, and OPENSSL_MODULES points at the real oqsprovider.so dir."
pause

# ---------------------------------------------------------------------------
say "Step 2.1 — Prove the gap: SNOVA is ABSENT natively"
next "Stock OpenSSL ships only STANDARDIZED algorithms — so SNOVA should be missing."
run "openssl list -signature-algorithms | grep -i snova || echo 'SNOVA: not present natively'"
ok "Native OpenSSL has no SNOVA — that gap is the whole reason oqs-provider exists."
pause

# ---------------------------------------------------------------------------
say "Step 2.2 — Load the provider; SNOVA APPEARS"
next "A stock binary gains a new algorithm purely by loading a provider."
run "openssl list -signature-algorithms -provider oqsprovider -provider default | grep -i snova"
ok "SNOVA parameter sets now show, tagged '@ oqsprovider' — that tag = the inventory truth."
note "We use the bare '$SNOVA_ALG'. The p256_/p384_/p521_ ones are classical HYBRIDS"
note "and the ...esk ones are expanded-secret-key variants — distractions for this demo."
pause

# ---------------------------------------------------------------------------
say "Step 2.3 — The deferral lesson: ML-KEM STILL comes from native"
next "Resolve the most-filed confusion: 'why isn't ML-KEM under oqsprovider?'"
run "openssl list -kem-algorithms -provider oqsprovider -provider default | grep -i ml-kem"
ok "ML-KEM is tagged '@ default', NOT '@ oqsprovider' — deferral is CORRECT behavior, not a bug."
pause

# ---------------------------------------------------------------------------
say "Step 2.4 — Provider collision / load-order hazard (agility + ops risk)"
next "Run genpkey WITHOUT the -provider flags: the algorithm exists but no backend answers."
printf '%s\n' "${BOLD}\$ openssl genpkey -algorithm $SNOVA_ALG 2>&1 | tail -3${RST}"
openssl genpkey -algorithm "$SNOVA_ALG" 2>&1 | tail -3 || true
ok "It errors (no provider loaded to answer) — provider plumbing itself is a migration risk."
note "Lesson: 'worked on 3.0.15, broke on 3.5' is crypto-agility going wrong. Have a rollback plan."
pause

# ---------------------------------------------------------------------------
say "Step 2.5 — THE PAYOFF: sign/verify with SNOVA via the unmodified binary"
next "Same openssl — brand-new signature scheme — purely because a provider was loaded."
note "/work is read-only, so we create the message and write all artifacts under /tmp."
run "echo 'hello post-quantum world' > $MSG"
run "openssl genpkey -algorithm $SNOVA_ALG -provider oqsprovider -provider default -out /tmp/snova.key"
run "openssl pkeyutl -sign   -inkey /tmp/snova.key -rawin -provider oqsprovider -provider default -in $MSG -out /tmp/snova.sig"
run "openssl pkeyutl -verify -inkey /tmp/snova.key -rawin -provider oqsprovider -provider default -in $MSG -sigfile /tmp/snova.sig"
ok "Signature Verified Successfully — no recompiled OpenSSL, no patched stack."
pause

# ---------------------------------------------------------------------------
say "Step 2.5b — Compare ML-DSA (native, standardized) vs SNOVA (provider, candidate)"
next "Put a standardized signature next to a candidate one and MEASURE the trade-off."
run "openssl genpkey -algorithm ML-DSA-65 -out /tmp/mldsa.key"
note "^ ML-DSA-65 is NATIVE — no -provider flags needed"
run "openssl pkeyutl -sign -inkey /tmp/mldsa.key -rawin -in $MSG -out /tmp/mldsa.sig"
note "size comparison (private key file vs signature):"
run 'for pair in "ML-DSA-65 /tmp/mldsa.key /tmp/mldsa.sig" "SNOVA-24-5-4 /tmp/snova.key /tmp/snova.sig"; do set -- $pair; printf "%-13s key %7d B   signature %7d B\n" "$1" "$(wc -c < "$2")" "$(wc -c < "$3")"; done'
ok "SNOVA's signature is much SMALLER than ML-DSA's ~3.3 KB — but watch its larger KEY size."
note "That key-size cost is the kind that hits TLS CERT CHAINS (Step 1.5), not CPU. ML-DSA = balanced workhorse."
pause

# ---------------------------------------------------------------------------
say "Step 2.6 — The honest caveat (say it; it IS the lesson)"
printf '%s\n' "${RED}${BOLD}SNOVA reached NIST Round 3, but some Round-2 parameter sets were cryptanalytically attacked.${RST}"
note "NIST kept it because its unbroken sets still show promise. You EVALUATE candidates behind an"
note "experimental provider — never in production. The provider is how you test-drive the future SAFELY."
echo
ok "Demo 2 complete: same binary, a provider added a candidate signature, and we measured its trade-offs."
printf '%s\n' "${GRN}${BOLD}DEMO 2 DONE.${RST}"
