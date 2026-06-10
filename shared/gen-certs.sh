#!/usr/bin/env bash
# =============================================================================
#  gen-certs.sh — build the PKI for the workshop
#
#  Produces, under ./certs/ :
#     ca-classical.{key,crt}   self-signed CA, classical (ECDSA P-256)
#     ca-mldsa.{key,crt}       self-signed CA, post-quantum (ML-DSA-65)
#     server-classical.{key,crt}  leaf signed by classical CA (ECDSA)
#     server-mldsa.{key,crt}       leaf signed by ML-DSA CA   (ML-DSA-65)
#
#  WHY TWO PKIs, NOT JUST TWO LEAF CERTS:
#  The PQC signing story is about the WHOLE chain. A classical CA signing a
#  PQC leaf is a half-measure that confuses more than it teaches. We build a
#  fully classical chain and a fully post-quantum chain so the contrast is
#  honest: every signature in the PQC chain is ML-DSA.
#
#  WHY SELF-SIGNED / LOCAL CA AND NOT A REAL CA:
#  As of 2026 no public CA issues post-quantum certificates. A local/self-
#  signed CA is not a workshop shortcut here — it is the ONLY way to get an
#  ML-DSA certificate chain at all. Worth stating plainly to the audience.
#
#  Requires OpenSSL >= 3.5 (for ML-DSA / ML-KEM). The script checks.
# =============================================================================
set -euo pipefail

CERTDIR="${1:-./certs}"
HOST="${HOST:-localhost}"
DAYS=30

# ---- version guard --------------------------------------------------------
ver=$(openssl version | awk '{print $2}')
case "$ver" in
  3.5*|3.6*|3.7*|3.8*|3.9*) : ;;
  *) echo "ERROR: need OpenSSL >= 3.5 for ML-DSA/ML-KEM. Found: $ver" >&2
     echo "       On Fedora: need Fedora 43+ (F42 ships 3.2.x, too old)." >&2
     echo "       Fedora 43+: sudo dnf install openssl wireshark-cli" >&2
     echo "       On older Fedora: run everything via the container path instead." >&2
     exit 1 ;;
esac

mkdir -p "$CERTDIR"
cd "$CERTDIR"

echo "==> Using $(openssl version)"
echo "==> Host (CN/SAN): $HOST"
echo

# A small SAN config so the leaf certs validate by hostname.
cat > san.cnf <<EOF
[req]
distinguished_name = dn
[dn]
[v3_req]
subjectAltName = DNS:${HOST}
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
EOF

# =====================================================================
#  CLASSICAL CHAIN  (ECDSA P-256 throughout)
# =====================================================================
echo "==> [classical] generating ECDSA CA + leaf"
openssl ecparam -name prime256v1 -genkey -noout -out ca-classical.key
openssl req -x509 -new -key ca-classical.key -sha256 -days $DAYS \
  -subj "/CN=Workshop Classical CA" -out ca-classical.crt

openssl ecparam -name prime256v1 -genkey -noout -out server-classical.key
openssl req -new -key server-classical.key \
  -subj "/CN=${HOST}" -out server-classical.csr
openssl x509 -req -in server-classical.csr \
  -CA ca-classical.crt -CAkey ca-classical.key -CAcreateserial \
  -days $DAYS -sha256 -extfile san.cnf -extensions v3_req \
  -out server-classical.crt

# =====================================================================
#  POST-QUANTUM CHAIN  (ML-DSA-65 throughout)
#  -newkey mldsa65 produces a key whose signatures are ML-DSA.
# =====================================================================
echo "==> [pqc] generating ML-DSA-65 CA + leaf"
openssl req -x509 -newkey mldsa65 -nodes \
  -keyout ca-mldsa.key -out ca-mldsa.crt \
  -subj "/CN=Workshop ML-DSA CA" -days $DAYS

openssl req -new -newkey mldsa65 -nodes \
  -keyout server-mldsa.key \
  -subj "/CN=${HOST}" -out server-mldsa.csr
openssl x509 -req -in server-mldsa.csr \
  -CA ca-mldsa.crt -CAkey ca-mldsa.key -CAcreateserial \
  -days $DAYS -extfile san.cnf -extensions v3_req \
  -out server-mldsa.crt

# =====================================================================
#  Show the size difference — this is a key teaching artifact.
# =====================================================================
echo
echo "==> Certificate & key sizes (bytes on disk) — note the PQC inflation:"
for f in ca-classical.crt server-classical.crt server-classical.key \
         ca-mldsa.crt server-mldsa.crt server-mldsa.key; do
  printf "    %-26s %8d\n" "$f" "$(wc -c < "$f")"
done

echo
echo "==> Verify each chain validates against its own CA:"
openssl verify -CAfile ca-classical.crt server-classical.crt
openssl verify -CAfile ca-mldsa.crt    server-mldsa.crt

echo
echo "==> Confirm the PQC leaf really uses ML-DSA (look for 'ML-DSA-65'):"
openssl x509 -in server-mldsa.crt -text -noout | grep -iE "Signature Algorithm|Public Key Algorithm" | head -2

rm -f *.csr san.cnf
echo
echo "==> Done. Certs are in: $CERTDIR"
