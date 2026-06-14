# Quantum-Safe TLS — Hands-On Lab (executable, line by line)

Companion to the talk **"Quantum-Safe TLS in Practice With Open Quantum Safe & OpenSSL 3."**
Every step is: **command → why we run it → expected output → what to look out for (which migration-checklist item it closes).**

> **Format note:** `[native]` steps need only stock OpenSSL **3.5+**. `[frontier]` steps need a built **oqs-provider**. Each crypto demo is structured so you can **pre-record it as a projector fallback**.

> ⚠️ **Verify on your actual demo box before presenting** (details at the end): `openssl version`; the SLH-DSA `pkeyutl -rawin` invocation; the SNOVA parameter-set spelling under your oqs-provider build; nginx/curl image tags; and venue network reality.

---

## Setup

Create a scratch directory to hold every key, cert, and signature the lab
produces, then run **all of Demo 1 inside a Fedora 43 container** so the steps
never depend on whatever OpenSSL your host happens to ship. Fedora 43's system
OpenSSL is **native 3.5**, which is exactly what every PQC command below needs.

```bash
# On the HOST: make a scratch dir that will hold every key/cert/sig
mkdir -p ~/pqc-lab

# Start a Fedora 43 container (= native OpenSSL 3.5) with that dir mounted
# read-WRITE at /work. Run ALL of Steps 1.1–1.9 inside THIS shell.
podman run --rm -it --name pqc-demo1 -w /work -v ~/pqc-lab:/work:Z fedora:43 bash
# Docker: docker run --rm -it --name pqc-demo1 -w /work -v ~/pqc-lab:/work fedora:43 bash

# --- you are now INSIDE the container ---
dnf -y install openssl && dnf clean all          # the openssl CLI (3.5 on F43)
echo "hello post-quantum world" > message.txt    # the payload we'll sign in Step 1.6
```

- **Why a container:** the headline of Demo 1 is "native, no provider" — but that
  only holds on OpenSSL **3.5+**. Pinning Fedora 43 guarantees it, so the demo is
  reproducible at the venue regardless of the host's OpenSSL.
- **`-v ~/pqc-lab:/work:Z` (read-WRITE):** Demo 1 *writes* certs and keys. They land
  in `~/pqc-lab` on the host and are **reused as-is** by the nginx container in
  Step 1.10. `:Z` relabels for SELinux (drop it on non-SELinux hosts / the Docker line).
- **`--name pqc-demo1`:** lets the two-terminal handshake steps (1.7–1.9) attach a
  **second shell** into the *same* container with
  `podman exec -it pqc-demo1 bash` — both shells share `localhost`, so the client
  reaches the server on `localhost:4433`.
- **`--rm`:** the container is removed when you exit the **last** shell. Leave this
  shell open for the whole of Demo 1.
- **`message.txt`:** an arbitrary file used only to demonstrate signing/verifying.

---

# DEMO 1 — "The present: deploy today" (native, no provider)

> **Opening confusion to quote:** *"I installed oqs-provider on OpenSSL 3.5, ran `openssl list`, and panicked that ML-KEM wasn't under it."* — By the end of Demo 1 you'll see why that's correct behavior.

### Step 1.1 — Ground truth: what version am I on?

```bash
openssl version
```

- **Why:** every PQC command below depends on native support that exists only in 3.5+.
- **Expect:** `OpenSSL 3.5.x` (or 3.6 / 4.0).
- **Look out for / closes [Readiness]:** if this says 3.0–3.4, *everything* below fails — and that failure is itself the readiness lesson. RHEL 9.6 and Fedora 43+ ship 3.5. Do not proceed past a version older than 3.5.

### Step 1.2 — Which provider actually answers for ML-DSA?

```bash
openssl list -providers
openssl list -signature-algorithms | grep -i ml-dsa
```

- **Why:** to prove the standardized algorithms come from *native* OpenSSL, not a plugin.
- **Expect:** only `default` (and `base`) loaded; ML-DSA entries tagged **`@ default`**.
- **Look out for / closes [Readiness — which provider]:** this directly answers the most-filed confusion. ML-KEM/ML-DSA are native. No oqs-provider in sight. The `@ default` tag is the inventory truth you'll check across your fleet.

### Step 1.3 — Build a 2-deep PQC cert chain (CA → leaf), zero special flags

```bash
# Root CA (ML-DSA-65), self-signed
openssl req -x509 -newkey mldsa65 -nodes \
  -keyout ca.key -out ca.crt \
  -subj "/CN=PQC Demo Root CA" -days 7

# Leaf key + CSR (ML-DSA-65)
openssl req -newkey mldsa65 -nodes \
  -keyout leaf.key -out leaf.csr \
  -subj "/CN=localhost"

# Sign the leaf with the CA
openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out leaf.crt -days 7

# Assemble the chain the server will present
cat leaf.crt ca.crt > chain.crt
```

What each block does:
- **Root CA (`-x509`):** `-x509` makes a *self-signed certificate* (the trust
  anchor), not a request. `-newkey mldsa65` generates a fresh ML-DSA-65 keypair;
  `-nodes` leaves the private key unencrypted (lab convenience); `-keyout`/`-out`
  name the key and cert; `-days 7` sets validity.
- **Leaf CSR (no `-x509`):** produces a *Certificate Signing Request* — the leaf's
  public key + identity (`CN=localhost`) awaiting the CA's signature. It is not yet
  a usable certificate.
- **Signing (`x509 -req`):** the CA reads the CSR and issues `leaf.crt`.
  `-CAcreateserial` creates the serial-number tracking file the CA needs.
- **Assembling (`cat`):** concatenates **leaf first, then CA** into `chain.crt` —
  the ordered bundle a TLS server presents so clients can build the trust path.

> To inspect the assembled chain later (both certs, human-readable):
> `openssl crl2pkcs7 -nocrl -certfile chain.crt | openssl pkcs7 -print_certs -text -noout`

- **Why:** a realistic handshake presents leaf + issuer, not one self-signed cert — and the *chain* is what blows up in size.
- **Expect:** all files created, no errors. It "just works" with no provider flags.
- **Look out for / closes [Readiness]:** the headline of this module — `mldsa65` is a *native* algorithm on 3.5. You did not load oqs-provider.

### Step 1.4 — Confirm the leaf really uses ML-DSA (don't trust the filename)

```bash
openssl x509 -in leaf.crt -text -noout \
  | grep -iE "Signature Algorithm|Public Key Algorithm" | head -2
```

- **Why:** filenames lie; certs don't.
- **Expect:** `ML-DSA-65` on both the public-key and signature lines.
- **Look out for / closes [Readiness — usable not just named]:** this verification habit is exactly what migration sign-off requires.

### Step 1.5 — The number that actually matters: full-chain size

```bash
# Classical control chain for contrast
openssl ecparam -name prime256v1 -genkey -noout -out ec-ca.key
openssl req -x509 -key ec-ca.key -sha256 -days 7 \
  -subj "/CN=Classical Demo CA" -out ec-ca.crt

# Compare sizes
for f in ec-ca.crt ca.crt leaf.crt chain.crt; do
  printf "%-14s %8d bytes\n" "$f" "$(wc -c < "$f")"
done
```

- **Why:** to make the real cost visible — and it's bytes, not CPU.
- **Expect:** the ML-DSA certs are kilobytes; the ECDSA cert is hundreds of bytes. `chain.crt` is the biggest.
- **Look out for / closes [Signatures/PKI — chain size; Cost — bytes not CPU]:** hold this number. A full PQC chain can approach or exceed the ~14 KB initial congestion window — that's where size turns into an extra round trip (Beat 4 / Step 1.9).

### Step 1.6 — The SLH-DSA anticlimax: native, standardized… and why nobody uses it for TLS

```bash
# Generate an SLH-DSA key (small key — that's its selling point)
openssl genpkey -algorithm SLH-DSA-SHA2-128s -out slh.key

# Sign the message — note -rawin (SLH-DSA is one-shot; NOT hash-then-sign)
openssl pkeyutl -sign -inkey slh.key -rawin \
  -in message.txt -out message.sig

# Verify
openssl pkeyutl -verify -inkey slh.key -rawin \
  -in message.txt -sigfile message.sig

# The cost
wc -c message.sig
```

- **Why:** to show all three FIPS algorithms are native — *and* to demonstrate, by contrast, why ML-DSA is the workhorse.
- **Expect:** `Signature Verified Successfully`; `message.sig` is roughly **7–8 KB** (vs ~3.3 KB for ML-DSA-65, vs ~64 B for ECDSA). The sign step is visibly slower.
- **Look out for / closes [Cost — the SLH-DSA outlier]:** this is the deliberate anticlimax. Fully native, fully FIPS-205 — but the signature is huge and signing is slow. *That's why* SLH-DSA is the conservative/niche choice and ML-DSA is the TLS default.
- **Gotcha:** you must use `pkeyutl -sign -rawin`. The familiar `openssl dgst -sign` (hash-then-sign) path does **not** apply — SLH-DSA does one-shot signing of the message itself. **Do NOT** build an SLH-DSA TLS cert chain in the talk; it works but eats time for marginal insight. Keep the handshake on ML-DSA.

### Step 1.7 — A real handshake; watch the negotiated group

This is the first time we actually *use* the cert chain in a live TLS handshake.
`s_server` is OpenSSL's built-in throwaway HTTPS server; `s_client` is its probe
client. We run them in **two shells into the same container** — keep the Setup
shell as **Terminal A** (server), and open **Terminal B** with
`podman exec -it pqc-demo1 bash` (client) — and inspect what TLS 1.3 picks on its own.

```bash
# Terminal A (the Setup shell) — server (leave it running; it holds port 4433)
openssl s_server -cert chain.crt -key leaf.key -www -tls1_3 -accept 4433

# Terminal B — open a 2nd shell into the SAME container, then run the client:
#   podman exec -it pqc-demo1 bash
echo "Q" | openssl s_client -connect localhost:4433 -tls1_3 -CAfile ca.crt 2>&1 \
  | grep -iE "group|Temp Key|signature type"
```

- **Server flags:**
  - `-cert chain.crt` / `-key leaf.key`: present the leaf→CA chain and prove key ownership.
  - `-www`: serve a simple status page so the connection completes like a real site.
  - `-tls1_3`: restrict to TLS 1.3 (so the negotiated group is unambiguous).
  - `-accept 4433`: listen on TCP 4433. **Only one process can hold this port** —
    see the teardown note below. (It's the *container's* 4433, not the host's — no
    `-p` publish needed since the client runs in the same container.)
- **Client flags:**
  - `echo "Q"`: feeds "Q" to quit the session immediately after the handshake.
  - `-CAfile ca.crt`: trust our demo root so the chain verifies cleanly (otherwise
    you get `unable to verify the first certificate` — harmless here, but noisy).
  - `2>&1`: merge stderr into stdout so `grep` can see the handshake summary.
- **Why:** to see what TLS 1.3 negotiates by default on 3.5.
- **Expect:** `Negotiated TLS1.3 group: X25519MLKEM768` and `Peer signature type: mldsa65`.
- **Look out for / closes [Key exchange — default hybrid]:** you didn't *ask* for PQC key exchange. 3.5 chose the hybrid by default. KEX is quietly already happening — that's the punchline.
- **Teardown / gotcha:** when done, stop the server with `Ctrl+C`. If you later see
  `Address already in use` on `bind()`, a previous `s_server` is still holding 4433 —
  free it with `fuser -k 4433/tcp` (or `pkill -f 's_server.*4433'`) before restarting.

### Step 1.8 — What a silent downgrade looks like

Same server as Step 1.7 (keep it running). Here we **handicap the client** to offer
only the classical `x25519` group and watch what happens to the key exchange.

```bash
echo "Q" | openssl s_client -connect localhost:4433 -tls1_3 \
  -groups x25519 -CAfile ca.crt 2>&1 | grep -iE "group|Temp Key|signature type"
```

- **`-groups x25519`:** restrict the client's key-share offer to pure classical
  X25519 — i.e. *no* ML-KEM on the table.
- **`-CAfile ca.crt`:** trust the demo root so the only thing left to notice is the
  *group*, not verification noise.
- **Why:** to make the downgrade risk concrete — one flag is all it takes.
- **Expect:** the key exchange falls back to classical. **Important grep tip:** on
  many 3.5 builds the `Negotiated TLS1.3 group:` line is only printed for *named/
  hybrid* groups; for pure classical X25519 the fallback shows up instead as
  **`Peer Temp Key: X25519, 253 bits`**. That's why the grep above also matches
  `Temp Key` — otherwise it looks (misleadingly) like nothing happened.
- **Note — KEX vs auth are independent:** even with classical X25519 key exchange,
  `Peer signature type: mldsa65` stays **post-quantum**. A downgrade can hit the
  *key exchange* without touching *authentication* — which is exactly why you must
  monitor the negotiated group in production, not just assume "the cert is PQC so
  we're fine."
- **If the handshake outright fails** (grep empty, server offers only the hybrid
  group): re-run without `| grep` to see the real outcome:
  `echo "Q" | openssl s_client -connect localhost:4433 -tls1_3 -groups x25519 -CAfile ca.crt 2>&1 | head -20`.
- **Look out for / closes [Key exchange — silent downgrade]:** a single misconfigured `-groups` (or a middlebox, or an old client) silently drops you back to classical with no error. This is what to monitor for in production.

### Step 1.9 — Interop: does a legacy client still connect?

Now we test the **opposite** risk: not silent downgrade, but a hard break. We point
a TLS **1.2** client (which knows nothing about PQC groups) at the server.

```bash
# A TLS 1.2 client (no PQC groups at all)
echo "Q" | openssl s_client -connect localhost:4433 -tls1_2 -CAfile ca.crt 2>&1 \
  | grep -iE "Protocol|Cipher" | head -2
```

- **`-tls1_2`:** force the client to speak only TLS 1.2.
- **`-CAfile ca.crt`:** trust the demo root so a *successful* TLS 1.2 connection
  verifies cleanly and you can focus on whether it connects at all.
- **Why:** migration must not break older clients.
- **Expect (dual-stack server):** it connects over TLS 1.2 with a classical cipher
  (the ML-DSA cert auth may or may not be accepted by a strict legacy verifier — note
  what happens).
- **Possible on your box:** if the server was started with `-tls1_3` (TLS-1.3-only),
  the TLS 1.2 client is **rejected outright** with
  `tlsv1 alert protocol version ... SSL alert number 70` and `Cipher is (NONE)`. That
  is a *hard-fail* interop result. To see graceful degradation instead, restart the
  server **without** `-tls1_3`:
  `openssl s_server -cert chain.crt -key leaf.key -www -accept 4433`.
- **Look out for / closes [Interop]:** confirm your dual-stack/hybrid posture keeps legacy clients working. Capability mismatch should degrade gracefully, not hard-fail.

### Step 1.10 — Real-app proof: curl + native-OpenSSL nginx

So far every handshake has used OpenSSL's own `s_server`/`s_client` lab tools. The
final proof is that a **real production web server** — nginx — does the exact same
PQC handshake with **zero PQC-specific configuration**, purely because it was built
against OpenSSL 3.5. We stand up nginx in a container so the demo is reproducible
and doesn't depend on your host's nginx build.

> **Where to run this:** Steps 1.10a–1.10g run on the **HOST** (a separate terminal),
> *not* inside the `pqc-demo1` shell. The certs you generated in Steps 1.3 are already
> on the host at `~/pqc-lab` (the read-write mount), so nginx can pick them up directly.
> You can leave `pqc-demo1` running (Step 1.7's server still holds *its* 4433 inside
> that container; nginx uses 8443 on the host — no conflict) or exit it first.

> **Key constraint:** the nginx must link against **native OpenSSL 3.5+**. The
> popular `nginx` Docker images and the QUIC/BoringSSL fork do **not** qualify —
> BoringSSL is a different crypto stack with different group names and no ML-KEM.
> The trick below uses a **Fedora 43 base image**, whose packaged nginx is built
> against the system's OpenSSL 3.5, so you get native PQC for free.

#### 1.10a — Create the nginx TLS config

This tells nginx to serve HTTPS on 8443 using the **same `chain.crt` + `leaf.key`**
you already generated, restricted to TLS 1.3 so the negotiated group is unambiguous.

```bash
cat > ~/pqc-lab/nginx-pqc.conf <<'EOF'
server {
    # Listen on BOTH IPv4 and IPv6 — curl resolves `localhost` to ::1 (IPv6)
    # first on most boxes, and if nginx only bound IPv4 the IPv6 connection is
    # accepted then reset by the port-forwarder ("Send failure: Broken pipe",
    # with nothing in nginx's log). Binding both stacks avoids that trap.
    listen 8443 ssl;
    listen [::]:8443 ssl;
    server_name localhost;

    # Reuse the ML-DSA chain and leaf key from Step 1.3
    ssl_certificate     /etc/nginx/certs/chain.crt;
    ssl_certificate_key /etc/nginx/certs/leaf.key;

    # Force TLS 1.3 so the hybrid PQC group is the only possible outcome
    ssl_protocols TLSv1.3;

    location / {
        return 200 "PQC nginx OK\n";
        default_type text/plain;
    }
}
EOF
```

- **`listen 8443 ssl;` + `listen [::]:8443 ssl;`:** bind **both** IPv4 and IPv6.
  Without the IPv6 line, `curl https://localhost:8443` typically tries `::1` first,
  gets a `Broken pipe` (the forwarder accepts then resets), and nginx logs nothing —
  a confusing dead end. Binding both makes `localhost` work regardless of how it
  resolves. (Alternatively, target IPv4 explicitly: `curl https://127.0.0.1:8443`.)
- **`ssl_certificate` = `chain.crt`:** nginx sends the full leaf→CA chain, not just
  the leaf — exactly the realistic, size-heavy presentation from Step 1.3/1.5.
- **`ssl_certificate_key` = `leaf.key`:** the leaf's private key proves ownership.
- **`ssl_protocols TLSv1.3`:** removes TLS 1.2 from the equation so you can clearly
  read the negotiated PQC group.

#### 1.10b — Create a Dockerfile for native-OpenSSL nginx

```bash
cat > ~/pqc-lab/Dockerfile <<'EOF'
# Fedora 43 ships OpenSSL 3.5 + an nginx built against it = native PQC support
FROM fedora:43
RUN dnf -y install nginx openssl && dnf clean all
COPY nginx-pqc.conf /etc/nginx/conf.d/pqc.conf
EXPOSE 8443
CMD ["nginx", "-g", "daemon off;"]
EOF
```

- **`FROM fedora:43`:** the base whose system OpenSSL is 3.5 — this is what makes
  the nginx inside "native-OpenSSL nginx."
- **`COPY ... /etc/nginx/conf.d/pqc.conf`:** drops our TLS server block into nginx's
  auto-included config directory.
- **`daemon off;`:** keeps nginx in the foreground so the container stays alive.

#### 1.10c — Build the image

```bash
cd ~/pqc-lab
podman build -t pqc-nginx .      # or: docker build -t pqc-nginx .
```

- **Why:** bakes nginx + OpenSSL 3.5 into a pinned, reproducible image.
- **Expect:** a successful build ending in `Successfully tagged ... pqc-nginx`.

#### 1.10d — Confirm the image really has OpenSSL 3.5

```bash
podman run --rm pqc-nginx openssl version   # or: docker run --rm pqc-nginx openssl version
```

- **Why:** never trust that "nginx image" == "PQC-capable." Verify the linked
  OpenSSL before relying on it (same "usable, not just named" discipline as 1.4).
- **Expect:** `OpenSSL 3.5.x`. If it says 3.0–3.4, stop — PQC will silently not work.

#### 1.10e — Run the container, mounting your certs

```bash
podman run --rm --name pqc-nginx -p 8443:8443 \
  -v ~/pqc-lab:/etc/nginx/certs:ro,Z \
  pqc-nginx
# Docker equivalent (drop the ,Z on non-SELinux hosts):
# docker run --rm --name pqc-nginx -p 8443:8443 -v ~/pqc-lab:/etc/nginx/certs:ro pqc-nginx
```

- **`--name pqc-nginx`:** a stable name so `podman logs pqc-nginx` / `podman exec
  pqc-nginx ...` work (without it podman auto-names the container, e.g.
  `nifty_driscoll`, and `podman logs pqc-nginx` errors with "no such container").
- **`-p 8443:8443`:** publishes the container's TLS port to your host. By default
  podman maps it on **both** IPv4 and IPv6, which pairs with the dual-stack
  `listen` in 1.10a so `curl https://localhost:8443` works no matter how `localhost`
  resolves.
- **`-v ~/pqc-lab:/etc/nginx/certs:ro`:** mounts your cert directory **read-only**
  so nginx finds `chain.crt`/`leaf.key` at the paths named in the config.
- **`,Z`:** relabels the volume for SELinux (needed on Fedora/RHEL; harmless to omit
  on systems without SELinux — see the Docker line).
- **Leave this terminal running** — the server stays in the foreground. Use a second
  terminal for the next command.

#### 1.10f — Hit it with curl and read the negotiated group

```bash
curl -v --tls-max 1.3 https://localhost:8443/ \
  --cacert ~/pqc-lab/ca.crt 2>&1 \
  | grep -iE "curve|group|SSL connection|ALPN|subject|issuer"
```

- **`--cacert ca.crt`:** tells curl to trust your demo root so verification
  succeeds (otherwise curl rejects the self-signed chain — add `-k` only if you
  want to bypass verification and just observe the group).
- **`--tls-max 1.3`:** pins the client to TLS 1.3.
- **Why:** prove the lesson with a production tool + production client, not a lab
  toy. This is the architect-credible version of Step 1.7.
- **Expect:** curl reports a TLS 1.3 connection negotiating the hybrid PQC group
  (e.g. `SSL connection using TLSv1.3 / ... / group: X25519MLKEM768`) and the
  `PQC nginx OK` body.
- **Gotcha — `Send failure: Broken pipe` / `unexpected eof while reading`:** if curl
  dies right after `Client hello` while `Trying [::1]:8443`, it hit the **IPv6**
  address but something in the path only bound IPv4. With the dual-stack `listen`
  from 1.10a this shouldn't happen; if it still does, force IPv4:
  `curl -v --tls-max 1.3 https://127.0.0.1:8443/ --cacert ~/pqc-lab/ca.crt`. A clean
  (empty) `podman logs` during this failure is the signature — nginx never saw the
  connection because the reset happened in the port-forwarder, not in nginx.
- **Look out for / closes [Key exchange — real app]:** same lesson as Step 1.7, but
  from a tool architects respect. **Pin the native-OpenSSL nginx image; avoid the
  QUIC/BoringSSL fork** (different stack, different group names). *Optional:* show a
  browser-devtools screenshot of a real site's `X25519MLKEM768` key share — "you're
  already doing this every day."

#### 1.10g — Tear down

```bash
# Stop the server: Ctrl+C in the terminal running the container.
# If you ran it detached, list and stop it:
podman ps                 # or: docker ps
podman stop <container>   # or: docker stop <container>
```

---

# DEMO 2 — "The frontier: how the community decides what you deploy in 5 years" (oqs-provider)

> **Opening confusion to quote:** *"Two providers loaded and `genpkey` failed with 'no encoders were found.'"* — load-order is a real migration hazard, and we'll see why.

> **Algorithm choice:** we use **SNOVA** — a NIST Additional-Signatures **Round 3** candidate (advanced May 2026). We deliberately do **not** use HQC: it's disabled-by-default in liboqs and flagged by two CVEs.

### Step 2.0 — Prerequisite: build oqs-provider in a container (no local toolchain needed)

Demo 2 needs an **oqs-provider** module, which isn't packaged in Fedora. You do
**not** need a local liboqs/cmake toolchain — build it **once inside a container**,
exactly like the nginx image in Step 1.10. The crucial requirement: oqs-provider
must link against the **same native OpenSSL 3.5** so the Step 2.3 deferral lesson
(ML-KEM stays `@ default`) actually shows up. Fedora 43 gives you that for free.

#### 2.0a — Create the oqs-provider Dockerfile

```bash
cat > ~/pqc-lab/Dockerfile.oqs <<'EOF'
# Fedora 43 = native OpenSSL 3.5. We add oqs-provider built against THAT OpenSSL,
# so standardized algos (ML-KEM/ML-DSA) keep deferring to @ default (Step 2.3).
FROM fedora:43

# Build deps + the system OpenSSL 3.5 headers
RUN dnf -y install git cmake gcc gcc-c++ ninja-build \
        openssl openssl-devel && dnf clean all

# 1) Build liboqs (pin a release tag — names/enabled sets drift between commits).
#    -DOQS_ENABLE_SIG_snova=ON ensures SNOVA is compiled in (off in some builds).
RUN git clone --depth 1 --branch 0.14.0 \
        https://github.com/open-quantum-safe/liboqs /src/liboqs && \
    cmake -S /src/liboqs -B /src/liboqs/build -GNinja \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DOQS_DIST_BUILD=ON \
        -DOQS_ENABLE_SIG_snova=ON && \
    cmake --build /src/liboqs/build --target install

# 2) Build oqs-provider against the system OpenSSL 3.5
#    NOTE: 0.10.0 is the FIRST release that exposes SNOVA to OpenSSL (PR #674);
#    0.9.0 has MAYO/CROSS/UOV but NOT SNOVA. 0.10.0 is in sync with liboqs 0.14.0.
RUN git clone --depth 1 --branch 0.10.0 \
        https://github.com/open-quantum-safe/oqs-provider /src/oqs-provider && \
    cmake -S /src/oqs-provider -B /src/oqs-provider/build -GNinja \
        -DCMAKE_PREFIX_PATH=/usr/local \
        -DOPENSSL_ROOT_DIR=/usr && \
    cmake --build /src/oqs-provider/build && \
    cmake --install /src/oqs-provider/build

# liboqs.so lives under /usr/local; make the loader find it at runtime
ENV LD_LIBRARY_PATH=/usr/local/lib64:/usr/local/lib
CMD ["/bin/bash"]
EOF
```

- **`FROM fedora:43`:** the same native-OpenSSL-3.5 base as the nginx image — this is
  what keeps the deferral lesson (Step 2.3) intact.
- **`--branch 0.14.0` / `0.10.0`:** pinned release tags — a **matched pair** (oqs-provider
  0.10.0 is in sync with liboqs 0.14.0). **SNOVA needs oqs-provider ≥ 0.10.0**: the
  earlier 0.9.0 exposes MAYO/CROSS/UOV but *not* SNOVA (SNOVA was added in 0.10.0,
  PR #674). **Verify current tags before the talk** — see the
  [liboqs releases](https://github.com/open-quantum-safe/liboqs/releases)
  and [oqs-provider releases](https://github.com/open-quantum-safe/oqs-provider/releases).
- **`-DOQS_ENABLE_SIG_snova=ON`:** forces SNOVA in at the **liboqs** layer; the
  provider tag (≥ 0.10.0) is what actually surfaces it to `openssl`.
- **`-DOPENSSL_ROOT_DIR=/usr`:** points the build at Fedora's **system** OpenSSL 3.5,
  not a private copy — this is the linkage that makes the deferral work.

#### 2.0b — Build the image

```bash
cd ~/pqc-lab
podman build -f Dockerfile.oqs -t pqc-oqs .      # or: docker build -f Dockerfile.oqs -t pqc-oqs .
```

- **Why:** bakes liboqs + oqs-provider + native OpenSSL 3.5 into one reproducible
  image — no toolchain on your laptop, nothing to break at the venue.
- **Expect:** a successful build ending in `Successfully tagged ... pqc-oqs`. The
  liboqs/oqs-provider compile takes a few minutes the first time.

#### 2.0c — Find the provider module path and confirm OpenSSL is 3.5

```bash
# Start an interactive shell in the image; mount your lab dir read-only for message.txt
podman run --rm -it -v ~/pqc-lab:/work:ro,Z pqc-oqs
# Docker: docker run --rm -it -v ~/pqc-lab:/work:ro pqc-oqs

# Inside the container:
openssl version                                   # must say OpenSSL 3.5.x
find / -name 'oqsprovider.so' 2>/dev/null         # note the directory it prints
# Point OpenSSL at that directory. The module installs under /usr/lib64, but
# this OpenSSL build's DEFAULT module search dir is /usr/local/lib64/ossl-modules,
# so the export below is REQUIRED (without it: "unable to load provider"):
export OPENSSL_MODULES=/usr/lib64/ossl-modules
```

- **Why:** `-provider oqsprovider` only works if OpenSSL can find `oqsprovider.so`.
  The build installs it under **`/usr/lib64/ossl-modules`**, but this OpenSSL
  binary's compiled-in default search dir is **`/usr/local/lib64/ossl-modules`** —
  so the two don't match and you **must** set `OPENSSL_MODULES` to the real dir.
  Skipping it gives `unable to load provider oqsprovider ... cannot open shared
  object file`.
- **Expect:** `OpenSSL 3.5.x`, and `find` printing
  `/usr/lib64/ossl-modules/oqsprovider.so` (plus a harmless build-tree copy under
  `/src/oqs-provider/build/lib/` — ignore that one). Use the `/usr/lib64` path.
- **Run all of Steps 2.1–2.6 inside this container shell** (where `OPENSSL_MODULES`
  is exported and `message.txt` is at `/work/message.txt`).

> **Alternatives:** (a) The OQS project's prebuilt image `openquantumsafe/oqs-ossl3`
> is faster (`podman pull openquantumsafe/oqs-ossl3`), but it bundles its **own**
> OpenSSL — which may not be 3.5-native, so the Step 2.3 deferral lesson can look
> different (ML-KEM may show under oqsprovider). Fine for the SNOVA sign/verify
> payoff, less clean for the teaching point — check `openssl version` inside it
> first. (b) If the build is shaky at the venue, **pre-record Steps 2.1–2.6** from
> this container as the projector fallback.

### Step 2.1 — Prove the gap: SNOVA is absent natively

```bash
openssl list -signature-algorithms | grep -i snova || echo "SNOVA: not present natively"
```

- **Why:** to motivate the provider — OpenSSL ships only standardized algorithms.
- **Expect:** nothing / the fallback message.
- **Look out for / closes [Readiness — listed vs usable]:** native OpenSSL does not ship un-standardized candidates. This gap is the whole reason oqs-provider exists.

### Step 2.2 — Load the provider; SNOVA appears

```bash
# REQUIRED: this OpenSSL build searches /usr/local/lib64/ossl-modules by default,
# but the module installed under /usr/lib64/ossl-modules — point it at the real dir
# (skip this and you get "unable to load provider oqsprovider"):
export OPENSSL_MODULES=/usr/lib64/ossl-modules
openssl list -signature-algorithms -provider oqsprovider -provider default \
  | grep -i snova
```

- **Why:** to show a stock binary gain a new algorithm purely by loading a provider.
- **Expect:** one or more SNOVA parameter sets, tagged **`@ oqsprovider`**.
- **Look out for / closes [Readiness — which provider]:** the `@ oqsprovider` tag tells you exactly which backend answers. That tag is the entire mental model for crypto inventory.
- **Gotcha:** the exact spelling of the SNOVA parameter set varies between liboqs builds. Discover it from *this* output — don't hardcode from a slide. On this build the bare sets are `snova2454`, `snova37172`, `snova2455`, `snova2965`; the `p256_`/`p384_`/`p521_` prefixes are classical-**hybrid** composites and `...esk` are expanded-secret-key variants. **Use the bare `snova2454`** for the demo — the rest are distractions.

### Step 2.3 — The deferral lesson: ML-KEM still comes from native

```bash
openssl list -kem-algorithms -provider oqsprovider -provider default \
  | grep -i ml-kem
```

- **Why:** to resolve the most-filed confusion directly.
- **Expect:** ML-KEM tagged **`@ default`**, *not* `@ oqsprovider`.
- **Look out for / closes [Readiness — which provider]:** oqs-provider 0.9.0+ deliberately defers standardized algorithms to native OpenSSL. The "missing ML-KEM under oqsprovider" that engineers panic about is **correct behavior, not a bug.** (Note: SNOVA itself needs oqs-provider **≥ 0.10.0** — 0.9.0 ships MAYO/CROSS/UOV but not SNOVA.)

### Step 2.4 — Provider collision (agility/ops hazard)

```bash
# Illustrative: with provider load-order/config wrong, encoder lookup can fail.
# If your environment reproduces it, capture the error; otherwise explain it.
openssl genpkey -algorithm snova2454 2>&1 | tail -3   # may error without -provider flags
```

- **Why:** to show that provider plumbing itself is a migration risk.
- **Expect (when it triggers):** an error such as `No encoders were found`.
- **Look out for / closes [Agility/ops]:** provider load-order and config are a real hazard — "it worked on 3.0.15, broke on 3.5" is the lived experience of crypto-agility going wrong. Have a rollback plan. **This step is the most environment-dependent — pre-record it; treat a live trigger as a bonus, and otherwise explain it at the screen.**

### Step 2.5 — The payoff: sign/verify with SNOVA via the unmodified binary

```bash
# This container mounts ~/pqc-lab at /work READ-ONLY, so create the message and
# write all artifacts under /tmp (writable). If /work/message.txt exists from
# Demo 1 you may use it instead; the line below makes the step self-contained.
echo "hello post-quantum world" > /tmp/message.txt

# Generate a SNOVA key (use the exact name from Step 2.2)
openssl genpkey -algorithm snova2454 \
  -provider oqsprovider -provider default -out /tmp/snova.key

# Sign and verify
openssl pkeyutl -sign -inkey /tmp/snova.key -rawin \
  -provider oqsprovider -provider default \
  -in /tmp/message.txt -out /tmp/snova.sig
openssl pkeyutl -verify -inkey /tmp/snova.key -rawin \
  -provider oqsprovider -provider default \
  -in /tmp/message.txt -sigfile /tmp/snova.sig
```

- **Why:** to prove the abstraction — the *same* OpenSSL binary performs a brand-new signature scheme purely because a provider was loaded.
- **Expect:** `Signature Verified Successfully`.
- **Gotcha (container paths):** the lab dir is mounted **read-only** at `/work`, so you **cannot** write keys/sigs there — keep all outputs in `/tmp`. Don't `cd /work` and run the commands as written in Demo 1; use the `/tmp` paths above.
- **Look out for / closes [Agility — crypto-agility]:** no recompiled OpenSSL, no patched stack. This is how the field test-drives candidates before standardization.

### Step 2.5b — Compare ML-DSA (native, standardized) vs SNOVA (provider, candidate)

This is the architect payoff: with the **same binary** you can put a *standardized*
signature and a *candidate* signature side by side and measure the trade — entirely
inside this container (ML-DSA is native, SNOVA comes from the provider).

```bash
# ML-DSA-65 — native, NO provider flags needed
openssl genpkey -algorithm ML-DSA-65 -out /tmp/mldsa.key
openssl pkeyutl -sign -inkey /tmp/mldsa.key -rawin \
  -in /tmp/message.txt -out /tmp/mldsa.sig

# SNOVA 24-5-4 — provider-supplied (key + sig already made in Step 2.5)

# Compare public-key and signature sizes
for pair in "ML-DSA-65 /tmp/mldsa.key /tmp/mldsa.sig" \
           "SNOVA-24-5-4 /tmp/snova.key /tmp/snova.sig"; do
  set -- $pair
  printf "%-13s pubkey+priv %6d B   signature %6d B\n" \
    "$1" "$(wc -c < "$2")" "$(wc -c < "$3")"
done
```

- **Why:** turns "frontier vs standardized" from a slogan into numbers — the only
  honest way to weigh a candidate. Both run through *one* OpenSSL.
- **Expect (rough, build-dependent):** ML-DSA-65 signature ≈ **3.3 KB**; SNOVA-24-5-4
  signature is **much smaller** (a few hundred bytes) — SNOVA's *selling point* is
  compact signatures. But SNOVA's **public key is large** (tens of KB), which is the
  opposite trade — and exactly the kind of cost that hits TLS **certificate chains**
  (Step 1.5), not CPU. ML-DSA is the balanced, standardized workhorse; SNOVA trades
  signature size for key size and is still a *candidate*.
- **Look out for / closes [Cost — bytes not CPU; Evaluate-not-deploy]:** the
  comparison makes the deployment decision concrete: a smaller signature looks
  attractive until the public-key/cert-chain cost shows up. This is *why* you
  evaluate behind a provider before betting a fleet on it (Step 2.6).
- **Gotcha:** `-rawin` is required for **both** (one-shot signing, not hash-then-sign),
  and SNOVA's sign/verify still need the `-provider` flags; ML-DSA does not.

### Step 2.6 — The honest caveat (say it; it IS the lesson)

> SNOVA advanced to **Round 3**, but **some of its Round-2 parameter sets were cryptanalytically attacked**; NIST kept it because its unbroken parameter sets still show promise. This is *exactly why* you evaluate candidates behind an experimental provider and never in production. The provider is how you test-drive the future safely — that caveat is the entire point of Demo 2.

---

## Migration checklist → demo-step map

| What to check | Step | Decision it informs |
|---|---|---|
| Library version ≥ 3.5 | 1.1 | Gates all native PQC |
| Which provider answers (`@ default` / `@ oqsprovider`) | 1.2, 2.2, 2.3 | Inventory truth; native deploys, provider evaluates |
| Listed vs usable | 1.4, 2.1, 2.2 | `openssl list` alone is not readiness |
| Default hybrid KEX correct | 1.7, 1.10 | KEX already solved; confirm you get it |
| Silent-downgrade risk | 1.8 | Misconfig drops to classical silently |
| Full-chain size vs ~14 KB | 1.5 | The real cost; extra-RTT risk |
| CPU vs bytes; SLH-DSA outlier | 1.6 | Measure the right thing |
| ML-DSA vs SNOVA size trade (sig vs pubkey) | 2.5b | Standardized workhorse vs candidate's trade-off |
| Provider collision / load-order | 2.4 | Crypto-agility + rollback discipline |
| Legacy client interop | 1.9 | Dual-stack / hybrid posture |
| Evaluate-not-deploy frontier algos | 2.1–2.6 | Provider = evaluation path only |

---

## Verify-on-the-box checklist (do this before presenting)

1. `openssl version` → confirm **3.5+** (RHEL 9.6 / Fedora 43+).
2. SLH-DSA: confirm `openssl genpkey -algorithm SLH-DSA-SHA2-128s` and `pkeyutl -sign -rawin` work **exactly as written** — this is the single command most likely to differ across builds.
3. SNOVA: `openssl list -signature-algorithms -provider oqsprovider | grep -i snova` → copy the **exact parameter-set spelling** into Steps 2.2/2.4/2.5.
4. nginx/curl: pull and run the **native-OpenSSL** nginx image (not the QUIC/BoringSSL fork); confirm curl's group-name output.
5. Provider path: set `OPENSSL_MODULES` to your build's actual module directory.
6. **Pin liboqs/oqs-provider release tags and build the container once** — algorithm names and enabled sets drift between commits (SPHINCS+→SLH-DSA in liboqs 0.16; Dilithium already removed).
7. Venue network: confirm before betting on any live remote/browser beat; otherwise use recordings.

> **The takeaway this lab exists to earn:** *Post-quantum TLS doesn't make handshakes slow — it makes authentication big, and big interacts badly with round trips and middleboxes; so migration work is certificate-chain sizing and crypto-agility, not faster CPUs.*
