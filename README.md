# Post-Quantum Cryptography in TLS — an open-source workshop

A hands-on workshop demonstrating what post-quantum cryptography (PQC)
actually changes in TLS, across **both** halves of the protocol:

- **Encryption / key exchange** — ML-KEM hybrid (`X25519MLKEM768`), the
  defense against "harvest now, decrypt later."
- **Signing / PKI** — ML-DSA certificates (`ML-DSA-65`), a fully
  post-quantum self-signed certificate chain.

Three modules:

| Module | Where | What it shows |
|--------|-------|---------------|
| **1** | Local Fedora desktop | Capture & decrypt four TLS handshakes in Wireshark, isolating the key-exchange change from the signature change. |
| **2** | kind (Kubernetes-in-Docker) cluster | The same PQC server running as a real deployment; probe it from the host as both a PQC-capable and a legacy client. |
| **3** | Local / container | OpenSSL **provider** architecture, and using **liboqs / oqs-provider** to *evaluate* non-standardized algorithms (HQC, BIKE, FrodoKEM, alternate signatures) that aren't in native OpenSSL. |

```
pqc-workshop/
├── shared/gen-certs.sh          # builds the classical + PQC PKI (run first)
├── module1-local/capture.sh     # local 4-way handshake capture
├── module2-kind/                # cluster deployment + probe
│   ├── kind-config.yaml
│   ├── deploy.sh
│   ├── probe.sh
│   ├── server-image/            # Fedora + OpenSSL 3.5 server image
│   └── manifests/pqc-server.yaml
└── module3-providers/           # providers + liboqs algorithm evaluation
    ├── build-oqs.sh             # compile liboqs + oqs-provider
    ├── evaluate.sh              # the provider-concept walkthrough
    └── Containerfile            # self-contained eval box (no host changes)
```

---

## The two things that make or break this workshop

**1. TLS 1.3 encrypts its own handshake.** Only ClientHello and ServerHello
are plaintext; the certificate and the rest are encrypted. A naive capture
shows almost nothing. The fix is `SSLKEYLOGFILE` — OpenSSL dumps the session
secrets, Wireshark uses them to decrypt the capture. Every capture script
here wires that up. Understanding *why* it's needed is itself a core lesson.

**2. Key exchange and signature are independent PQC choices.** "PQC in TLS"
is not one switch. Key exchange (ML-KEM) protects the session secret —
that's the urgent part, because recorded traffic can be decrypted later if a
quantum computer arrives. Signatures (ML-DSA) authenticate at handshake time
and are **not** retroactively breakable the same way, so they migrate on a
slower clock. Module 1's four-case matrix exists specifically to let you see
these two axes move independently rather than as one blurry "PQC" toggle.

---

## Proportionate framing (please read before presenting)

It is easy to oversell this topic. Keep it honest:

- Large-scale quantum computers that can break X25519 or RSA **do not exist
  today**, and credible timelines span from "over a decade" to "maybe
  never." The reason to act now is narrow and specific: the *recording*
  risk for data that must stay confidential for many years. That is a real,
  defensible motivation — it does not need apocalyptic framing to stand up.
- **Hybrid** key exchange (`X25519MLKEM768`) means the session key is derived
  from *both* X25519 and ML-KEM. You're only exposed if both break. This is
  why browsers and CDNs (Chrome, Firefox, Cloudflare, Google) chose the
  hybrid rather than pure ML-KEM — ML-KEM is young, and the hedge is cheap.
- PQC **signatures** are the less mature half of the story. They work in
  OpenSSL 3.5, but no public CA issues PQC certificates yet, so a local /
  self-signed CA is the *only* way to get an ML-DSA chain in 2026 — not a
  workshop shortcut, a current fact of the ecosystem.

---

## Prerequisites

**Module 1 (local):**
- **OpenSSL 3.5+.** This is the hard requirement for ML-KEM/ML-DSA.
  Note: **Fedora 42 ships OpenSSL 3.2.x, which is too old.** You need
  **Fedora 43 or newer** (43 was the first Fedora with 3.5). Check with
  `openssl version`. If you're on F42 or earlier, use the container path
  (Module 2's image) for everything instead of the host binary.
- `tshark` — `sudo dnf install wireshark-cli`
- Wireshark GUI for analysis — `sudo dnf install wireshark`

**Module 2 (cluster):** `docker` (or `podman`), `kind`, `kubectl`. The
server image is Fedora 43-based, so the cluster gets OpenSSL 3.5 regardless
of your host's OpenSSL version — handy if your desktop is on F42.

---

## Module 1 — local capture & decrypt

```bash
cd pqc-workshop
./shared/gen-certs.sh ./module1-local/certs    # build the PKI
cd module1-local
./capture.sh                                    # runs 4 handshakes
```

This produces, in `module1-local/out/`, a `.pcap` + `.keys` pair for each of
four cases (label = KEX axis + signature axis):

| Label | Key exchange      | Signature            |
|-------|-------------------|----------------------|
| `cc`  | X25519 (classical)| ECDSA (classical)    |
| `cp`  | X25519 (classical)| ML-DSA-65 (PQC)      |
| `pc`  | X25519MLKEM768    | ECDSA (classical)    |
| `pp`  | X25519MLKEM768    | ML-DSA-65 (PQC)      |

### Analyze in Wireshark

1. **Preferences → Protocols → TLS → "(Pre)-Master-Secret log filename"** →
   point at the `.keys` file for the capture you're opening (each capture has
   its own; swap when you swap captures).
2. **File → Open** the matching `.pcap`. Filter: `tls`.

### What to point at

- **`cc` vs `pc` (the encryption axis):** expand the ClientHello →
  `key_share`. Classical X25519 is a 32-byte share. `X25519MLKEM768`
  balloons to ~1.2 KB. **That size jump is the post-quantum key material on
  the wire** — the single most visible difference. The ServerHello in the
  PQC case carries an ML-KEM *ciphertext* (~1.1 KB): the server encapsulates
  to the client's key rather than sending its own DH share. Structurally
  different from classical Diffie-Hellman — name that out loud.
- **`cc` vs `cp` (the signature axis):** with the keylog loaded, find the
  Certificate message. The ML-DSA certificate and its CertificateVerify
  signature are dramatically larger than ECDSA. The console output reports
  `Peer signature type: mldsa65` vs an ECDSA type.
- **What stays identical everywhere:** TLS 1.3, the symmetric cipher
  (AES-GCM), the overall handshake shape. Only the asymmetric pieces change.
  That bounds the honest scope of "PQC in TLS" today.

---

## Module 2 — the kind cluster

```bash
cd pqc-workshop
./shared/gen-certs.sh ./module2-kind/certs     # PKI for the cluster
cd module2-kind
./deploy.sh                                     # cluster up, build, deploy
./probe.sh                                      # connect from host + capture
```

### Why this is built the way it is

- **No ingress controller.** `ingress-nginx` was archived in March 2026 (no
  more security fixes); building a 2026 workshop on it would teach a dead
  component. Instead the OpenSSL 3.5 server runs **directly in a pod**,
  exposed via a **NodePort** that kind maps to `localhost:30443`. The crypto
  path is then exactly what you configured — nothing in between can silently
  downgrade it.
- **Dual certificate serving.** The pod serves the ML-DSA cert *and* a
  classical cert (`-cert` + `-dcert`). `probe.sh` then connects twice — once
  forcing the PQC hybrid group, once forcing classical — against the *same*
  service. PQC-capable client gets PQC; legacy client still connects. That
  is the migration story compressed to one screen.

### What to point at

`probe.sh` writes `out-cluster/pqc-client.pcap` and
`out-cluster/classical-client.pcap` (+ `.keys`). Expected console:

- `pqc-client` → `Negotiated TLS1.3 group: X25519MLKEM768`
- `classical-client` → `Server Temp Key: X25519, 253 bits`

Open both in Wireshark the same way as Module 1. The teaching point: the
server didn't change between the two captures — the *client's capability*
did, and that alone determined whether the connection got post-quantum
protection. This is precisely the dynamic you'll manage during a real
fleet migration.

### Teardown

```bash
kind delete cluster --name pqc-workshop
```

### Worth mentioning to the audience

Go 1.24+ enables `X25519MLKEM768` **by default**. So many Go-based servers
(much of the Kubernetes ecosystem) already negotiate PQC key exchange with
no special build — the gap is mostly in older proxies and in PQC
*certificates*, not in key exchange. A pleasant surprise worth a slide.

---

## Module 3 — OpenSSL providers & evaluating new algorithms with liboqs

```bash
cd pqc-workshop/module3-providers
# Option A — self-contained container (recommended; touches nothing on host):
podman build -t pqc-oqs-eval -f Containerfile .
podman run --rm -it pqc-oqs-eval
#   then inside:  ./evaluate.sh
#
# Option B — build on the host (compiles C, installs a provider in your tree):
./build-oqs.sh          # then follow the printed export lines
./evaluate.sh
```

### The concept this module teaches

An OpenSSL 3 **provider** is a pluggable crypto backend. OpenSSL ships
`default` (normal algorithms, including native ML-KEM/ML-DSA on 3.5+),
`fips`, and `legacy`. Every algorithm in `openssl list` is tagged with the
provider that supplies it (`@ default`, `@ oqsprovider`) — that tag *is* the
mental model: PQC migration is partly a question of which provider answers
for which algorithm. `evaluate.sh` walks this in six steps, ending with a
candidate algorithm going through a real TLS handshake purely because a
provider was loaded — no recompiled OpenSSL.

### The crucial framing — why liboqs is NOT how you get ML-KEM

This is the easy thing to get wrong, so it's worth stating plainly to the
audience. **You do not need liboqs for the standardized algorithms.** OpenSSL
3.5 has ML-KEM and ML-DSA natively, and that native path (Modules 1–2) is the
correct one for production. In fact `oqs-provider` 0.9.0+ *deliberately
disables its own ML-KEM and ML-DSA* when it detects OpenSSL 3.5+, deferring
to native — so if you load it on a 3.5 box and grep for ML-KEM under
`oqsprovider`, you won't find it. That absence is not a bug; it's the lesson.

liboqs / oqs-provider earns its place for a *different* job: **evaluating
algorithms that are not standardized, not yet in native OpenSSL, or kept for
diversity** — HQC and BIKE (code-based KEMs), FrodoKEM (conservative
lattice), and alternate signatures (SLH-DSA, FN-DSA/Falcon, SNOVA, LMS). The
module enables **HQC** specifically (it's disabled by default even in liboqs)
as the worked "evaluate a new algorithm" example: generate keys, run it in a
handshake via a hybrid group, and benchmark size vs speed with liboqs's own
`speed_kem` / `speed_sig` harnesses.

So the three modules together tell one coherent story:

- **Modules 1–2 (native):** how you *deploy* standardized PQC today.
- **Module 3 (liboqs):** how you *evaluate* what might come next — and why,
  in 2026, that's a research/diversity tool rather than your TLS production
  path.

### What to point at

- `openssl list -providers` before and after loading `oqsprovider` — the
  provider list literally grows.
- The `@ oqsprovider` tag appearing on HQC/BIKE/FrodoKEM, and the *absence*
  of ML-KEM under it on 3.5+ (the deferral).
- The size-vs-speed tradeoff for code-based KEMs: HQC and BIKE buy a very
  different security assumption (codes, not lattices) at the cost of larger
  keys/ciphertexts — exactly the kind of finding a TLS-focused evaluation
  exists to surface.

---

## Worth mentioning to the audience (Modules 1–2)

Go 1.24+ enables `X25519MLKEM768` **by default**. So many Go-based servers
(much of the Kubernetes ecosystem) already negotiate PQC key exchange with
no special build — the gap is mostly in older proxies and in PQC
*certificates*, not in key exchange. A pleasant surprise worth a slide.

---

## Verification status (honest note)

This was authored and partially executed against OpenSSL 3.0, so a specific
split applies:

- **Executed and confirmed working:** certificate-chain generation logic,
  the `s_server`/`s_client` orchestration and argument structure, the
  `SSLKEYLOGFILE` → Wireshark decryption flow (verified end-to-end on a
  classical handshake), all script syntax, and all YAML/manifest validity.
- **Confirmed correct by environment, not run here:** OpenSSL 3.0 *rejects*
  `mldsa65` and exposes no ML-KEM groups, which is exactly why the version
  guards exist — they were observed firing. The `-newkey mldsa65` cert flow,
  the `X25519MLKEM768` negotiation, and the `Peer signature type: mldsa65`
  output match Red Hat's and OpenSSL's published 3.5 documentation, but were
  **not** executed on 3.5 in authoring. Run `./shared/gen-certs.sh` once on
  your real Fedora 43+ box before presenting; if anything differs, the
  `openssl version` line each script prints is the first thing to check.
- **kind NodePort-via-extraPortMappings** is the documented, standard pattern
  and the config follows it (nodePort == containerPort == 30443).
- **Module 3 (liboqs) is the least pre-validated and most fragile part.** It
  compiles liboqs and oqs-provider from their `main`/`master` branches, which
  move constantly — algorithm names (e.g. `hqc128` vs other spellings), the
  exact set of enabled algorithms, and the hybrid-group identifiers can all
  shift between commits. `evaluate.sh` is deliberately written to *not* abort
  on a missing algorithm (it reports the absence as an evaluation finding),
  but you should expect to adjust algorithm names to match what your build
  actually advertises. **Pin specific liboqs / oqs-provider release tags**
  (set `LIBOQS_REF` / `OQSPROV_REF`) before a live session rather than
  tracking `main`. The container build (`Containerfile`) includes a
  build-time smoke test that both providers load, so a successful image build
  is your signal that the core path works.

Do a full dry run on the actual presentation hardware. The crypto specifics
are sound per current docs, but "works on the projector" is a separate claim
from "syntactically valid," and only you can make the first one.

---

## Troubleshooting

- **Only "Application Data" in Wireshark, no handshake** — keylog not loaded
  or mismatched to the capture. Each `.pcap` needs *its own* `.keys`.
- **`gen-certs.sh` fails on `mldsa65`** — OpenSSL < 3.5. Check `openssl
  version`; on Fedora you need 43+.
- **`probe.sh` PQC run negotiates X25519, not the hybrid** — the server
  isn't offering the hybrid group, or your host OpenSSL is < 3.5 and can't
  *send* the hybrid key share. Check both ends' versions.
- **NodePort unreachable from host** — the Service `nodePort` must equal the
  `containerPort` in `kind-config.yaml` (both 30443). They bind by number.
- **kind can't find the image** — re-run `kind load docker-image
  pqc-workshop-server:local --name pqc-workshop`; `imagePullPolicy` is
  `IfNotPresent` so it won't try a registry.
- **(M3) `oqsprovider` not listed after loading** — `OPENSSL_MODULES` isn't
  pointing at the directory containing `oqsprovider.so`, or `LD_LIBRARY_PATH`
  is missing the liboqs `lib64`. The container sets both for you.
- **(M3) ML-KEM doesn't appear under oqsprovider** — expected on OpenSSL
  3.5+; oqs-provider defers to native. Not a failure.
- **(M3) HQC / a hybrid group is missing** — your liboqs build didn't enable
  it (HQC needs `-DOQS_ENABLE_KEM_HQC=ON`, which the scripts set) or the
  algorithm name changed upstream. List what's actually present with
  `openssl list -kem-algorithms -provider oqsprovider` and adjust.
