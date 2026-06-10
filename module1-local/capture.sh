#!/usr/bin/env bash
# =============================================================================
#  Module 1 — Local Fedora desktop: capture & decrypt PQC TLS handshakes
#
#  Runs four TLS 1.3 handshakes on loopback and captures each, crossing the
#  two independent axes PQC touches:
#
#                       | classical signature | ML-DSA signature
#     ------------------+---------------------+------------------
#     classical KEX     |  cc  (all classical)|  cp
#     ML-KEM hybrid KEX |  pc                 |  pp  (all PQC)
#
#  This separation is the point: in TLS, KEY EXCHANGE and SIGNATURE are
#  independent choices. "PQC in TLS" is not one switch. The matrix lets the
#  audience see the encryption-side change (KEX, the harvest-now-decrypt-
#  later defense) apart from the authentication-side change (signature).
#
#  Each run writes a .pcap and a matching .keys (SSLKEYLOGFILE). TLS 1.3
#  encrypts the handshake after ServerHello, so the .keys file is what makes
#  the capture readable in Wireshark. Without it this demo shows nothing.
#
#  Requires: openssl >= 3.5, tshark (Fedora: sudo dnf install openssl wireshark-cli)
#  Run certs first:  ../shared/gen-certs.sh ./certs
# =============================================================================
set -euo pipefail

CERTDIR="${CERTDIR:-./certs}"
OUT="${OUT:-./out}"
PORT="${PORT:-4433}"
IFACE="${IFACE:-lo}"

CLASSICAL_KEX="x25519"
PQC_KEX="X25519MLKEM768"
# OpenSSL signature-algorithm tokens for -sigalgs:
CLASSICAL_SIG="ecdsa_secp256r1_sha256"
PQC_SIG="mldsa65"

# ---- preflight ------------------------------------------------------------
command -v tshark >/dev/null || { echo "tshark not found. sudo dnf install wireshark-cli" >&2; exit 1; }
ver=$(openssl version | awk '{print $2}')
case "$ver" in 3.5*|3.6*|3.7*|3.8*|3.9*) : ;; *) echo "Need OpenSSL>=3.5, found $ver" >&2; exit 1;; esac
[ -f "$CERTDIR/server-mldsa.crt" ] || { echo "Run ../shared/gen-certs.sh $CERTDIR first" >&2; exit 1; }

mkdir -p "$OUT"
echo "==> $(openssl version)"
echo "==> capturing on interface '$IFACE', port $PORT"
echo

# ---------------------------------------------------------------------------
#  run_case LABEL  KEX_GROUP  SIG_ALG  SERVER_CERT  SERVER_KEY  CA_FILE
# ---------------------------------------------------------------------------
run_case () {
  local label="$1" kex="$2" sig="$3" cert="$4" key="$5" ca="$6"
  local pcap="$OUT/${label}.pcap" keys="$OUT/${label}.keys"

  echo "------------------------------------------------------------"
  echo "  $label :  KEX=$kex  SIG=$sig"
  echo "------------------------------------------------------------"
  : > "$keys"

  tshark -i "$IFACE" -f "tcp port $PORT" -w "$pcap" -q >/dev/null 2>&1 &
  local tpid=$!; sleep 1

  # Server pinned to one group; serves the chosen cert. keylogfile dumps secrets.
  openssl s_server -accept "$PORT" \
    -cert "$CERTDIR/$cert" -key "$CERTDIR/$key" \
    -tls1_3 -groups "$kex" \
    -keylogfile "$keys" -www >/dev/null 2>&1 &
  local spid=$!; sleep 1

  # Client pins the same KEX group and constrains the signature alg it accepts,
  # then prints the three lines that prove what was negotiated.
  echo "GET / HTTP/1.0" | openssl s_client \
    -connect "localhost:$PORT" \
    -tls1_3 -groups "$kex" -sigalgs "$sig" \
    -CAfile "$CERTDIR/$ca" \
    -keylogfile "$keys" 2>/dev/null | \
    grep -E "Negotiated TLS|Server Temp Key|Peer signature type|Protocol|Cipher" || true

  sleep 1
  kill "$spid" "$tpid" 2>/dev/null || true
  wait "$spid" "$tpid" 2>/dev/null || true
  echo "    -> $pcap  +  $keys"
  echo
}

#                label  KEX             SIG             cert                    key                     ca
run_case "cc"   "$CLASSICAL_KEX" "$CLASSICAL_SIG" "server-classical.crt" "server-classical.key" "ca-classical.crt"
run_case "cp"   "$CLASSICAL_KEX" "$PQC_SIG"       "server-mldsa.crt"     "server-mldsa.key"     "ca-mldsa.crt"
run_case "pc"   "$PQC_KEX"       "$CLASSICAL_SIG" "server-classical.crt" "server-classical.key" "ca-classical.crt"
run_case "pp"   "$PQC_KEX"       "$PQC_SIG"       "server-mldsa.crt"     "server-mldsa.key"     "ca-mldsa.crt"

# ---- ClientHello size comparison (the visible "PQC is bigger") ------------
echo "============================================================"
echo "  ClientHello size by case (bytes) — KEX drives KEX-share size"
echo "============================================================"
for label in cc cp pc pp; do
  # pull the first TLS handshake record length as a rough proxy
  sz=$(tshark -r "$OUT/${label}.pcap" -Y "tls.handshake.type==1" \
        -T fields -e frame.len 2>/dev/null | head -1)
  printf "    %-4s ClientHello frame: %s bytes\n" "$label" "${sz:-n/a}"
done
echo
echo "==> Open each .pcap in Wireshark with its matching .keys (see README)."
