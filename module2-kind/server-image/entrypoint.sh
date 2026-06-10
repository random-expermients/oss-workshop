#!/usr/bin/env bash
# Pod entrypoint: run a TLS 1.3 server with PQC enabled.
#
# Env (set in the Deployment):
#   KEX_GROUPS   key-exchange groups to offer (default: PQC hybrid + classical)
#   CERT / KEY   primary (PQC, ML-DSA) cert+key
#   DCERT / DKEY secondary (classical RSA/ECDSA) cert+key  [optional]
#
# Serving BOTH a PQC and a classical cert (-cert + -dcert) is the realistic
# migration posture: PQC-capable clients get the ML-DSA chain, older clients
# still connect on the classical one. This is what "demonstrate the impact
# without breaking compatibility" looks like in a real deployment.
set -euo pipefail

KEX_GROUPS="${KEX_GROUPS:-X25519MLKEM768:x25519}"
CERT="${CERT:-/certs/server-mldsa.crt}"
KEY="${KEY:-/certs/server-mldsa.key}"
DCERT="${DCERT:-/certs/server-classical.crt}"
DKEY="${DKEY:-/certs/server-classical.key}"
PORT="${PORT:-8443}"

echo "==> $(openssl version)"
echo "==> KEX groups offered: $KEX_GROUPS"
echo "==> primary cert (PQC):       $CERT"

ARGS=(-accept "$PORT" -tls1_3 -groups "$KEX_GROUPS"
      -cert "$CERT" -key "$KEY" -www -quiet)

# Add the classical fallback cert only if it's present.
if [ -f "$DCERT" ] && [ -f "$DKEY" ]; then
  echo "==> fallback cert (classical): $DCERT"
  ARGS+=(-dcert "$DCERT" -dkey "$DKEY")
fi

echo "==> starting openssl s_server on :$PORT"
exec openssl s_server "${ARGS[@]}"
