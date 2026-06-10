# =============================================================================
#  Module 2 server image — a Fedora-based OpenSSL 3.5 PQC TLS server
#
#  We deliberately run the OpenSSL s_server inside the pod rather than relying
#  on an ingress controller, because:
#    * ingress-nginx was ARCHIVED in March 2026 (no security fixes) — not a
#      thing to teach people to deploy in 2026.
#    * A proxy's PQC capability depends entirely on the OpenSSL IT was built
#      against; routing through one means you no longer control the crypto
#      path, and the demo can silently fall back to classical.
#  Running s_server directly = the crypto path is exactly what we configured.
#
#  OpenSSL 3.5 first appears in Fedora 43 (F42 still ships 3.2.x). We pin F43
#  and verify at build time so a too-old base fails loudly instead of silently
#  producing a non-PQC server.
# =============================================================================
FROM fedora:43

RUN dnf -y install openssl && dnf clean all

# Fail the build loudly if the base image's OpenSSL is too old for ML-KEM/ML-DSA.
RUN openssl version | grep -qE 'OpenSSL 3\.(5|6|7|8|9)' \
    || (echo "ERROR: need OpenSSL >= 3.5; got $(openssl version)" && exit 1)

WORKDIR /certs
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Certs are mounted at /certs from a Secret. Group is configurable via env.
EXPOSE 8443
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
