#!/usr/bin/env bash
# =============================================================================
#  Module 2 — probe.sh : connect to the in-cluster server from the host and
#  demonstrate the PQC impact, with a capture you can open in Wireshark.
#
#  Because the server offers BOTH X25519MLKEM768 and x25519, we probe it two
#  ways from the host to show the cluster behaves like a real mixed fleet:
#     pqc-client       : forces the hybrid group  -> negotiates PQC
#     classical-client : forces x25519 only        -> negotiates classical
#  Same server, same Service, different client capability = different result.
#  That is the migration story in one screen.
#
#  Requires openssl>=3.5 and tshark on the host. Captures loopback :30443.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

CERTDIR="${CERTDIR:-../certs}"
OUT="${OUT:-./out-cluster}"
HOSTPORT="${HOSTPORT:-30443}"
IFACE="${IFACE:-lo}"
mkdir -p "$OUT"

probe () {
  local label="$1" groups="$2"
  local pcap="$OUT/${label}.pcap" keys="$OUT/${label}.keys"
  echo "------------------------------------------------------------"
  echo "  $label  (client offers groups: $groups)"
  echo "------------------------------------------------------------"
  : > "$keys"
  tshark -i "$IFACE" -f "tcp port $HOSTPORT" -w "$pcap" -q >/dev/null 2>&1 &
  local tpid=$!; sleep 1

  echo "GET / HTTP/1.0" | openssl s_client \
    -connect "localhost:$HOSTPORT" \
    -tls1_3 -groups "$groups" \
    -CAfile "$CERTDIR/ca-mldsa.crt" \
    -verify_return_error \
    -keylogfile "$keys" 2>/dev/null | \
    grep -E "Negotiated TLS|Server Temp Key|Peer signature type|Protocol|Cipher" || true

  sleep 1; kill "$tpid" 2>/dev/null || true; wait "$tpid" 2>/dev/null || true
  echo "    -> $pcap  +  $keys"
  echo
}

# Note: the classical probe trusts the ML-DSA CA but forces a classical KEX;
# the server's -dcert classical chain answers it. To also exercise the
# classical CA, swap -CAfile to ca-classical.crt for the classical run.
probe "pqc-client"       "X25519MLKEM768"
probe "classical-client" "x25519"

echo "==> Compare the two .pcap files in Wireshark (load matching .keys)."
echo "    pqc-client should show:  Negotiated TLS1.3 group: X25519MLKEM768"
echo "    classical-client:        Server Temp Key: X25519, 253 bits"
