#!/usr/bin/env bash
# =============================================================================
#  Module 2 — deploy.sh : stand up the PQC server in a kind cluster
#
#  Steps:
#    1. create the kind cluster (with the :30443 NodePort mapping)
#    2. build the Fedora/OpenSSL-3.5 server image
#    3. load the image into the cluster (kind load — no registry needed)
#    4. create a Secret from the certs gen-certs.sh produced
#    5. apply the Deployment + NodePort Service
#
#  Prereqs on the Fedora host: docker (or podman), kind, kubectl.
#  Certs must already exist:  ../shared/gen-certs.sh ./certs
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

CERTDIR="${CERTDIR:-./certs}"
IMAGE="pqc-workshop-server:local"
CLUSTER="pqc-workshop"

for bin in kind kubectl docker; do
  command -v "$bin" >/dev/null || { echo "Missing '$bin' on PATH." >&2; exit 1; }
done
[ -f "$CERTDIR/server-mldsa.crt" ] || { echo "Run ../shared/gen-certs.sh $CERTDIR first." >&2; exit 1; }

echo "==> [1/5] creating kind cluster '$CLUSTER'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "    (already exists, reusing)"
else
  kind create cluster --config kind-config.yaml
fi

echo "==> [2/5] building server image"
docker build -t "$IMAGE" server-image/

echo "==> [3/5] loading image into the cluster"
kind load docker-image "$IMAGE" --name "$CLUSTER"

echo "==> [4/5] creating/refreshing the cert Secret"
kubectl delete secret pqc-certs --ignore-not-found
kubectl create secret generic pqc-certs \
  --from-file=server-mldsa.crt="$CERTDIR/server-mldsa.crt" \
  --from-file=server-mldsa.key="$CERTDIR/server-mldsa.key" \
  --from-file=server-classical.crt="$CERTDIR/server-classical.crt" \
  --from-file=server-classical.key="$CERTDIR/server-classical.key"

echo "==> [5/5] applying Deployment + Service"
kubectl apply -f manifests/pqc-server.yaml
kubectl rollout status deploy/pqc-server --timeout=90s

echo
echo "==> Up. The server is reachable from the host at: https://localhost:30443"
echo "    Probe it:   ./probe.sh"
echo "    Tear down:  kind delete cluster --name $CLUSTER"
