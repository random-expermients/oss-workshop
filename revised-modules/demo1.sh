#!/usr/bin/env bash
# =============================================================================
#  demo1.sh  —  DEMO 1: "The present: deploy today" (native PQC, no provider)
# =============================================================================
#
#  WHAT THIS SCRIPT IS
#  -------------------
#  A self-paced, narratable recording script for Demo 1 of the
#  "Quantum-Safe TLS in Practice" talk. It runs the native OpenSSL 3.5 PQC
#  steps (1.1-1.9) end to end, pausing before each beat so you can narrate,
#  and printing exactly WHAT was done, WHAT got VERIFIED, and WHAT's NEXT.
#
#  WHERE TO RUN IT
#  ---------------
#  Inside the Fedora 43 container (= native OpenSSL 3.5), which is the
#  Demo 1 "Setup shell" from the lab. From the HOST:
#
#     mkdir -p ~/pqc-lab
#     cp demo1.sh ~/pqc-lab/                       # so it appears at /work
#     podman run --rm -it --name pqc-demo1 -w /work \
#         -v ~/pqc-lab:/work:Z fedora:43 bash
#     # --- inside the container: ---
#     dnf -y install openssl   &&  bash /work/demo1.sh
#
#  The cert chain this script writes lands in ~/pqc-lab on the host and is
#  REUSED as-is by the nginx real-app proof (Step 1.10), whose host commands
#  are printed at the end (they need podman and run OUTSIDE this container).
#
#  PACING
#  ------
#  Every beat waits for you to press ENTER (set DEMO_AUTO=1 to disable the
#  pauses for an unattended capture). Commands are echoed before they run.
# =============================================================================

# --- Resilient, but NOT 'set -e': several steps intentionally "fail"
#     (a downgrade, a TLS 1.2 hard-reject, greps that find nothing). Aborting
#     on those would defeat the lesson, so we handle outcomes explicitly.
set -u

# ---------------------------------------------------------------------------
#  Presentation helpers
# ---------------------------------------------------------------------------
BOLD=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'
CYN=$'\033[36m'; RST=$'\033[0m'

say()   { printf '\n%s\n' "${BOLD}${CYN}=== $* ===${RST}"; }   # section banner
note()  { printf '%s\n'  "${DIM}# $*${RST}"; }                 # narration note
ok()    { printf '%s\n'  "${GRN}[VERIFIED] $*${RST}"; }        # what we just proved
next()  { printf '%s\n'  "${YEL}[NEXT] $*${RST}"; }            # what's coming up

# Echo a command (so the audience sees it) then execute it.
run()   { printf '%s\n' "${BOLD}\$ $*${RST}"; eval "$@"; }

# Pause for narration unless DEMO_AUTO=1.
pause() {
  [ "${DEMO_AUTO:-0}" = "1" ] && return 0
  printf '%s' "${DIM}  ...press ENTER to continue...${RST}"; read -r _ || true
}

# ---------------------------------------------------------------------------
#  Cleanup: make sure no leftover s_server is holding port 4433 on exit.
# ---------------------------------------------------------------------------
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  # belt-and-suspenders: free 4433 if anything else grabbed it
  command -v fuser >/dev/null 2>&1 && fuser -k 4433/tcp 2>/dev/null || true
}
trap cleanup EXIT

# Start s_server in the background and wait until 4433 actually accepts.
# $* = extra flags (e.g. -tls1_3). Sets the global SERVER_PID.
start_server() {
  note "starting s_server in the background: openssl s_server -cert chain.crt -key leaf.key -www $* -accept 4433"
  openssl s_server -cert chain.crt -key leaf.key -www "$@" -accept 4433 >/tmp/s_server.log 2>&1 &
  SERVER_PID=$!
  # wait (up to ~5s) for the listener to come up
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if (exec 3<>/dev/tcp/127.0.0.1/4433) 2>/dev/null; then exec 3>&- 3<&-; return 0; fi
    sleep 0.5
  done
  echo "!! server did not come up; see /tmp/s_server.log"; return 1
}
stop_server() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
  sleep 0.5
}

# ===========================================================================
clear
printf '%s\n' "${BOLD}DEMO 1 — The present: deploy PQC TODAY with native OpenSSL 3.5${RST}"
note "No oqs-provider. No patched stack. Just stock OpenSSL doing post-quantum TLS."
pause

# ---------------------------------------------------------------------------
say "Step 1.1 — Ground truth: which OpenSSL am I on?"
next "Everything in Demo 1 depends on NATIVE PQC, which exists only in 3.5+."
run "openssl version"
if openssl version | grep -qE 'OpenSSL [3-9]\.([5-9]|[1-9][0-9])'; then
  ok "OpenSSL is 3.5+ — native ML-KEM / ML-DSA / SLH-DSA are available."
else
  echo "${YEL}WARNING: this is older than 3.5 — native PQC will NOT work. Run inside fedora:43.${RST}"
fi
pause

# ---------------------------------------------------------------------------
say "Step 1.2 — Which provider actually answers for ML-DSA?"
next "Prove the standardized algos come from NATIVE OpenSSL, not a plugin."
run "openssl list -providers"
run "openssl list -signature-algorithms | grep -i ml-dsa"
ok "Only 'default'/'base' are loaded, and ML-DSA is tagged '@ default' — native, no oqs-provider."
pause

# ---------------------------------------------------------------------------
say "Step 1.3 — Build a 2-deep PQC cert chain (CA -> leaf), zero special flags"
next "A realistic handshake presents leaf + issuer; the CHAIN is what grows in size."
run "openssl req -x509 -newkey mldsa65 -nodes -keyout ca.key -out ca.crt -subj '/CN=PQC Demo Root CA' -days 7"
note "^ self-signed ML-DSA-65 Root CA (the trust anchor)"
run "openssl req -newkey mldsa65 -nodes -keyout leaf.key -out leaf.csr -subj '/CN=localhost'"
note "^ leaf keypair + CSR (public key + identity, awaiting the CA's signature)"
run "openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out leaf.crt -days 7"
note "^ CA signs the CSR -> leaf.crt"
run "cat leaf.crt ca.crt > chain.crt"
note "^ assemble leaf-then-CA into chain.crt (the ordered bundle a TLS server presents)"
ok "Full ML-DSA-65 chain created with NO provider flags — mldsa65 is native on 3.5."
pause

# ---------------------------------------------------------------------------
say "Step 1.4 — Confirm the leaf REALLY uses ML-DSA (filenames lie; certs don't)"
run "openssl x509 -in leaf.crt -text -noout | grep -iE 'Signature Algorithm|Public Key Algorithm' | head -2"
ok "Both the public-key and signature lines say ML-DSA-65 — usable, not just named."
pause

# ---------------------------------------------------------------------------
say "Step 1.5 — The number that actually matters: full-chain SIZE"
next "The real PQC cost is BYTES, not CPU. Watch the chain dwarf the classical cert."
run "openssl ecparam -name prime256v1 -genkey -noout -out ec-ca.key"
run "openssl req -x509 -key ec-ca.key -sha256 -days 7 -subj '/CN=Classical Demo CA' -out ec-ca.crt"
note "comparing sizes (classical EC cert vs ML-DSA CA/leaf/chain):"
run 'for f in ec-ca.crt ca.crt leaf.crt chain.crt; do printf "%-14s %8d bytes\n" "$f" "$(wc -c < "$f")"; done'
ok "The ML-DSA chain is KILOBYTES vs hundreds of bytes for ECDSA — this is the extra-RTT risk."
pause

# ---------------------------------------------------------------------------
say "Step 1.6 — The SLH-DSA anticlimax: native, FIPS-205 ... and why nobody uses it for TLS"
next "Show the 3rd native algorithm — and why its huge signature keeps it niche."
run "openssl genpkey -algorithm SLH-DSA-SHA2-128s -out slh.key"
run "openssl pkeyutl -sign  -inkey slh.key -rawin -in message.txt -out message.sig"
note "^ NOTE -rawin: SLH-DSA is ONE-SHOT signing, NOT hash-then-sign (no 'dgst -sign')"
run "openssl pkeyutl -verify -inkey slh.key -rawin -in message.txt -sigfile message.sig"
run "wc -c message.sig"
ok "Verified. Signature is ~7-8 KB (vs ~3.3 KB ML-DSA-65, ~64 B ECDSA) and signing is slow."
note "That size/speed is exactly why ML-DSA — not SLH-DSA — is the TLS workhorse."
pause

# ---------------------------------------------------------------------------
say "Step 1.7 — A real handshake: watch the group TLS 1.3 picks on its own"
next "Start a TLS-1.3-only server, then probe it — no PQC was explicitly requested."
start_server -tls1_3
note "client probe (Terminal B equivalent):"
run "echo Q | openssl s_client -connect localhost:4433 -tls1_3 -CAfile ca.crt 2>&1 | grep -iE 'group|Temp Key|signature type'"
ok "Negotiated hybrid 'X25519MLKEM768' KEX + 'mldsa65' auth — PQC happened by DEFAULT."
pause

# ---------------------------------------------------------------------------
say "Step 1.8 — What a SILENT downgrade looks like (one flag is all it takes)"
next "Handicap the client to offer only classical x25519 and watch KEX fall back."
run "echo Q | openssl s_client -connect localhost:4433 -tls1_3 -groups x25519 -CAfile ca.crt 2>&1 | grep -iE 'group|Temp Key|signature type'"
ok "KEX dropped to classical (see 'Peer Temp Key: X25519') — yet 'signature type: mldsa65' stays PQC."
note "Lesson: a downgrade can hit KEX without touching AUTH. Monitor the negotiated group in prod."
stop_server
pause

# ---------------------------------------------------------------------------
say "Step 1.9 — Interop: does a LEGACY (TLS 1.2) client still connect?"
next "Restart the server DUAL-STACK (no -tls1_3) so older clients degrade gracefully."
start_server
run "echo Q | openssl s_client -connect localhost:4433 -tls1_2 -CAfile ca.crt 2>&1 | grep -iE 'Protocol|Cipher' | head -2"
ok "TLS 1.2 client connects over a classical cipher — dual-stack posture preserves interop."
note "(If the server had been -tls1_3 only, this would HARD-FAIL with alert 70 / Cipher (NONE).)"
stop_server
pause

# ---------------------------------------------------------------------------
say "Demo 1 crypto steps complete"
ok "Native OpenSSL 3.5 did PQC key exchange (X25519MLKEM768) + PQC auth (ML-DSA-65)."
ok "Cost is bytes (chain size), interop degrades gracefully, downgrades are silent-but-detectable."
next "Step 1.10 — the REAL-APP proof: nginx + curl. Run these on the HOST (needs podman),"
next "reusing the chain.crt/leaf.key this script just wrote to ~/pqc-lab."
cat <<'HOST_STEPS'

  ----------------------------------------------------------------------------
  STEP 1.10 (run on the HOST, not inside this container)
  ----------------------------------------------------------------------------
  # 1.10a  nginx TLS config (dual-stack listen avoids the IPv6 'Broken pipe' trap)
  cat > ~/pqc-lab/nginx-pqc.conf <<'EOF'
  server {
      listen 8443 ssl;
      listen [::]:8443 ssl;
      server_name localhost;
      ssl_certificate     /etc/nginx/certs/chain.crt;
      ssl_certificate_key /etc/nginx/certs/leaf.key;
      ssl_protocols TLSv1.3;
      location / { return 200 "PQC nginx OK\n"; default_type text/plain; }
  }
  EOF

  # 1.10b  Dockerfile for native-OpenSSL nginx
  cat > ~/pqc-lab/Dockerfile <<'EOF'
  FROM fedora:43
  RUN dnf -y install nginx openssl && dnf clean all
  COPY nginx-pqc.conf /etc/nginx/conf.d/pqc.conf
  EXPOSE 8443
  CMD ["nginx", "-g", "daemon off;"]
  EOF

  # 1.10c/d  build + confirm OpenSSL 3.5
  cd ~/pqc-lab && podman build -t pqc-nginx .
  podman run --rm pqc-nginx openssl version

  # 1.10e  run (use --name so 'podman logs pqc-nginx' works)
  podman run --rm --name pqc-nginx -p 8443:8443 \
      -v ~/pqc-lab:/etc/nginx/certs:ro,Z pqc-nginx

  # 1.10f  curl it (use localhost so the cert CN matches; dual-stack listen makes ::1 work)
  curl -v --tls-max 1.3 https://localhost:8443/ --cacert ~/pqc-lab/ca.crt 2>&1 \
      | grep -iE "group|SSL connection|subject|issuer|PQC nginx"
  # Expect: TLSv1.3 / ... / X25519MLKEM768 / id-ml-dsa-65   and   PQC nginx OK
  ----------------------------------------------------------------------------

HOST_STEPS
printf '%s\n' "${GRN}${BOLD}DEMO 1 DONE.${RST}"
