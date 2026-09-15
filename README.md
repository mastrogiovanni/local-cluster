# k8s-local

Local Kubernetes development environment using [Kind](https://kind.sigs.k8s.io/) and [Contour](https://projectcontour.io/) ingress.

`make up` here brings up **cluster basics only**: Kind, Contour, the `k8s-local` namespace, and a shared Contour `ingress-root` HTTPProxy. Apps live in sibling directories and are added with their own `make up`:

- [`../echo-proxy`](../echo-proxy) → `https://mastrogiovanni.ddns.net/echo-proxy`
- [`../temporal`](../temporal) → `https://mastrogiovanni.ddns.net/temporal`
- [`../../sprar`](../../sprar) → `https://mastrogiovanni.ddns.net/sprar`

An optional Kubernetes Dashboard can be enabled via Makefile targets.

## Architecture

```
host :80 / :443  (Kind extraPortMappings on 0.0.0.0)
    │
    ▼
Contour Envoy (hostPort 80/443)
    │
    ▼
HTTPProxy ingress-root (INGRESS_HOST; TLS after make cert)
    │  HTTP Basic Auth after make auth (TLS required)
    ├── /echo-proxy  →  ../echo-proxy
    ├── /temporal    →  ../temporal (Web UI)
    └── /sprar       →  ../../sprar (SAI Fatture UI)
```

App directories register path includes on `ingress-root`. After they are deployed, Contour forwards those prefixes on `INGRESS_HOST`.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Go 1.23+](https://go.dev/dl/) (optional, for running apps such as echo-proxy outside Docker)
- [Helm 3](https://helm.sh/docs/intro/install/) (required for the optional Temporal stack and Kubernetes Dashboard)
- Localhost ports **80** and **443** must be free (Kind binds Contour there)

For GPU workloads (e.g. sprar Baidu OCR), you also need:

- NVIDIA driver (`nvidia-smi` works on the host)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) configured for Docker
- A quick sanity check: `docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu22.04 nvidia-smi`

## Configuration

Edit [`config.env`](config.env) to set the ingress hostname Contour matches on (and, for TLS, a Let's Encrypt email):

```bash
INGRESS_HOST=mastrogiovanni.ddns.net
ACME_EMAIL=you@example.com
```

You can also override it for a single command:

```bash
make up INGRESS_HOST=echo.local
```

Add the host to `/etc/hosts` if you want to open it in a browser without a `Host` header:

```text
127.0.0.1 mastrogiovanni.ddns.net
```

Kind extraPortMappings and the `data-plane` extraMount are applied only when the cluster is created. After changing `cluster/cluster.yaml` or `cluster/cluster.gpu.yaml` (including the localhost 80/443 mappings, GPU mounts, or the host data directory), recreate the cluster with `make down && make up`.

## Quick start

From this directory:

```bash
make up
cd ../echo-proxy && make up
cd ../temporal && make up
cd ../../sprar && make up
```

`k8s/ make up` will:

1. Create the Kind cluster `k8s` (if it does not exist)
2. Install Contour, the `k8s-local` namespace, and `ingress-root`

Then each app directory builds images (if needed) and registers its Contour path.

The Kubernetes Dashboard is **not** installed by default. To include it:

```bash
make up WITH_DASHBOARD=1
```

### GPU-enabled cluster (optional)

For apps that request `nvidia.com/gpu` (sprar Baidu OCR), recreate the cluster with GPU support and install the NVIDIA device plugin:

```bash
make down
make up WITH_GPU=1
make gpu-status
```

`WITH_GPU=1` uses `cluster/cluster.gpu.yaml` (NVIDIA runtime in containerd + host toolkit mounts). The device plugin is applied automatically during `make up WITH_GPU=1`.

On an existing GPU cluster you can reinstall the plugin without recreating Kind:

```bash
make gpu
make gpu-status
```

Host checks run via `scripts/check-gpu-prereqs.sh`. Kind requires volume-mount mode in `/etc/nvidia-container-runtime/config.toml`:

```bash
sudo nvidia-ctk config --set accept-nvidia-visible-devices-as-volume-mounts=true --in-place
sudo systemctl restart docker
```

`cluster/cluster.gpu.yaml` mounts `/dev/null` at `/var/run/nvidia-container-devices/all` inside the Kind node (the host does **not** need `/var/run/nvidia-container-devices`). If toolkit binaries live outside `/usr/bin`, adjust `extraMounts` before `make down && make up WITH_GPU=1`.

On hosts with **multiple GPUs**, only the RTX 4060 family is exposed to Kind. `make gpu` runs `scripts/configure-kind-gpu-device.sh`, which sets `NVIDIA_VISIBLE_DEVICES` on the Kind node container to `GPU_DEVICE_UUID` from `config.env` (auto-detected if unset). `make gpu-status` should show **GPU: 1**. If a workload still reports a GTX 1060, re-run `make gpu` and restart GPU pods.

Test echo-proxy through Contour (hostname from `config.env`):

```bash
curl -H "Host: mastrogiovanni.ddns.net" http://127.0.0.1/echo-proxy
curl https://mastrogiovanni.ddns.net/echo-proxy
```

Example response:

```text
Server address: 10.244.0.17:8080
Server name: echo-app-5bbc4477df-jdpv6
Date: 04/Aug/2026:23:12:01 +0000
URI: /echo-proxy
Request ID: 72584852e66dd2db6463d2bb3ff180f7
```

Remove only echo-proxy (cluster stays up):

```bash
cd ../echo-proxy && make down
```

Tear down the cluster:

```bash
make down
```

## Makefile targets

| Target | Description |
|--------|-------------|
| `make up` | Create cluster and deploy platform (Contour, namespace, ingress-root) |
| `make up INGRESS_HOST=...` | Same as `make up`, overriding the hostname from `config.env` |
| `make up WITH_DASHBOARD=1` | Same as `make up`, then install the Kubernetes Dashboard |
| `make up WITH_AUTH=1` | Same as `make up`, then install HTTP Basic Auth (attaches only after TLS) |
| `make down` | Delete the Kind cluster |
| `make cluster` | Create the Kind cluster only |
| `make platform` | Install Contour, apply Kustomize manifests, ensure ingress-root |
| `make ingress-root` | Create or update the shared Contour HTTPProxy (preserves app includes) |
| `make cert-manager` | Install cert-manager in the Kind cluster |
| `make cert` | Install cert-manager, issue a Let's Encrypt cert, attach TLS to ingress-root |
| `make auth` | Install contour-authserver and require HTTP Basic Auth on TLS ingress |
| `make auth-user AUTH_USER=...` | Create or update an HTTP Basic user (random password if `AUTH_PASS` is omitted) |
| `make auth-users` | List HTTP Basic usernames |
| `make auth-user-delete AUTH_USER=...` | Remove an HTTP Basic user |
| `make auth-off` / `make auth-status` | Detach auth from ingress-root, or print whether it is attached |
| `make dashboard` | Install the Kubernetes Dashboard, metrics-server, and admin login user |
| `make dashboard-token` | Print the admin bearer token used to sign in |
| `make dashboard-proxy` | Fallback port-forward if Kind's `:8443` mapping is missing |
| `make dashboard-open` / `make dashboard-ui` | Install if needed, print/copy the token, and open `https://127.0.0.1:8443` |

## Project layout

Apps live in sibling directories (`../echo-proxy`, `../temporal`) and [`../../sprar`](../../sprar).

```
.
├── Makefile                 # Cluster basics automation
├── AUTH.md                  # Ingress HTTP Basic Auth architecture
├── config.env               # Ingress hostname (INGRESS_HOST)
├── cluster/
│   └── cluster.yaml         # Kind config (port mappings, data-plane extraMount)
├── base/
│   ├── kustomization.yaml
│   └── namespace.yaml       # k8s-local namespace
├── platform/
│   ├── kustomization.yaml   # Contour-adjacent platform manifests
│   ├── httpproxy.yaml
│   ├── auth/                # contour-authserver (HTTP Basic Auth)
│   └── cert/
│       ├── kustomization.yaml
│       ├── cluster-issuer.yaml
│       └── certificate.yaml
├── scripts/
│   ├── httpproxy-include.sh # Add/remove app path includes on ingress-root
│   ├── httpproxy-auth.sh    # Attach/detach HTTP Basic Auth on ingress-root
│   └── htpasswd-user.sh     # Create/list/delete htpasswd users
└── dashboard/
    ├── kustomization.yaml
    ├── values.yaml          # Dashboard Helm values (Kind)
    └── admin-user.yaml      # Admin ServiceAccount + token
```

## Developing the echo app

The echo app lives in [`../echo-proxy`](../echo-proxy). It returns request metadata (pod name, IP, URI, request ID) at `/echo-proxy` and exposes `/healthz` for probes.

After changing Go code:

```bash
cd ../echo-proxy && make redeploy
```

See [../echo-proxy/README.md](../echo-proxy/README.md) for image build details and environment variables.

## Optional Temporal HA stack

Temporal lives in [`../temporal`](../temporal). After the Kind cluster exists:

```bash
cd ../temporal && make up
```

The Web UI is served by Contour at `https://mastrogiovanni.ddns.net/temporal`. See [../temporal/README.md](../temporal/README.md) for workers, demos, and teardown (`make down`).

```
Go worker pods (HPA-ready, 3 replicas)     Python worker pods (3 replicas)
                 \                         /
                  \       gRPC :7233      /
                   v                     v
              Temporal frontend / history / matching (3+ each)
                              |
                              v
                     PostgreSQL (in-cluster)
```

Install after the Kind cluster exists:

```bash
cd ../temporal && make up
```

Worker images use `imagePullPolicy: Never` and must be loaded into Kind, same as echo-proxy. After code changes:

```bash
cd ../temporal && make redeploy-workers
```

Frontend address inside the cluster:

```text
temporal-frontend.temporal.svc.cluster.local:7233
```

Task queues:

| Worker | Task queue |
|--------|------------|
| Go | `go-task-queue` |
| Python | `python-task-queue` |

The Go worker registers `EchoWorkflow`. The Python worker matches the resilience project: it runs in a Python+`uv` image and registers `SayHelloWorkflow` plus `Python`, which takes a Python script string and executes it with `uv run` (PEP 723 inline dependencies are downloaded at activity time).

Start sample workflows:

```bash
cd ../temporal && make demo
```

`make demo` in `../temporal` starts:

- `EchoWorkflow` on `go-task-queue`
- `SayHelloWorkflow` on `python-task-queue`
- `Python` on `python-task-queue`, using `examples/fetch_json.py`

To run a script the same way as `resilience/starter.py` (start the `Python` workflow, wait, print stdout):

```bash
cd ../temporal && make python-demo
```

The Makefile port-forwards `temporal-frontend:7233`, then runs the host `starter/` uv project with a script path (default `examples/fetch_json.py`). The worker image does not contain the starter or example scripts.

Use a different file:

```bash
cd ../temporal && make python-demo SCRIPT=/path/to/your_script.py
```

`uv` must be installed on the host. The worker receives the script source and runs `uv run script.py`.

Then in the UI, set the namespace to **default** (top left) and look at:

| Where | What you should see |
|-------|---------------------|
| **Workflows** | `go-echo-*`, `python-hello-*` (`SayHelloWorkflow`), `python-script-*` (`Python`) |
| **Task Queues** → `go-task-queue` | Go worker pollers |
| **Task Queues** → `python-task-queue` | Python worker pollers |
| **Workers** | Heartbeating Go and Python workers (after the server picks up dynamic config) |

Search the task queue names if they are not listed yet; pollers still exist even when the list is empty.

Open the Temporal UI with:

```bash
cd ../temporal && make ui
```

That opens `https://mastrogiovanni.ddns.net/temporal`. Helm values live in [`../temporal/values.yaml`](../temporal/values.yaml).

## SAI Fatture (sprar)

The invoice UI lives in [`../../sprar`](../../sprar). After the Kind cluster exists:

```bash
cd ../../sprar && make up
```

Contour serves it at `https://mastrogiovanni.ddns.net/sprar`. SQLite and uploads persist on the host in [`../../data-plane/sprar`](../../data-plane/sprar) via a hostPath PV (Kind extraMount). `make down` in sprar removes only the app; host files stay.

### Baidu OCR (GPU)

Sprar can use [Baidu Unlimited-OCR](https://github.com/baidu/Unlimited-OCR) instead of Tesseract. The cluster must advertise `nvidia.com/gpu`:

```bash
# From this directory (control-plane/k8s)
make down && make up WITH_GPU=1
make gpu-status    # should show GPU: 1 (or your GPU count)

# Deploy sprar with the CUDA image
cd ../../sprar && make up OCR=baidu
```

The sprar pod uses `runtimeClassName: nvidia` and requests one GPU. First OCR run downloads the Hugging Face model inside the pod (large, slow). Without `WITH_GPU=1`, `make up OCR=baidu` leaves the pod **Pending** (`Insufficient nvidia.com/gpu`).

## Kubernetes Dashboard

The Kubernetes Dashboard is opt-in. It is a web UI for inspecting namespaces, workloads, pods, logs, and events. This local install also enables **metrics-server** so CPU/memory graphs can appear (Kind kubelets use self-signed certs, so the chart is configured with `--kubelet-insecure-tls`).

The upstream project is archived; this repo still installs it because it is the familiar cluster UI and works well on Kind. The Helm chart is pulled from `https://kubernetes-retired.github.io/dashboard/` (the old `kubernetes.github.io` index returns 404). Values live in `dashboard/values.yaml`.

The Helm chart ships Kong as an HTTPS gateway. Token login **only works over HTTPS**. Kind maps host `8443` to Kong's NodePort (`30443`). Contour stays on localhost `80`/`443`.

```
Browser  →  https://127.0.0.1:8443  →  Kind extraPortMapping
                                              │
                                              v
                               kubernetes-dashboard-kong-proxy:443
                                              │
                    +-------------------------+-------------------------+
                    v                         v                         v
              dashboard-web              dashboard-api              dashboard-auth
```

### Install

After the Kind cluster exists:

```bash
make dashboard
```

Or with the rest of the stack:

```bash
make up WITH_DASHBOARD=1
```

This will:

1. Install the Dashboard Helm release in namespace `kubernetes-dashboard` (Kong gateway, web, API, auth, metrics-scraper)
2. Install metrics-server (Kind-compatible flags)
3. Create an `admin-user` ServiceAccount bound to `cluster-admin`
4. Create a long-lived token Secret so you can sign in

`cluster-admin` is appropriate for this local Kind cluster only. Do not reuse this pattern on a shared or production cluster.

### Open and sign in

One command installs (if needed), prints the token, copies it to the clipboard when `pbcopy`/`xclip`/`wl-copy` is available, and opens the browser:

```bash
make dashboard-open
# or
make dashboard-ui
```

Then in the browser:

1. Open [https://127.0.0.1:8443](https://127.0.0.1:8443) if it did not open automatically
2. Accept the self-signed certificate warning (Kong uses a cluster-internal cert)
   - Chrome: **Advanced → Proceed to 127.0.0.1** (or type `thisisunsafe` on the warning page)
   - Safari: **Show Details → visit this website**
   - Firefox: **Advanced → Accept the Risk and Continue**
3. Choose **Token** (not kubeconfig)
4. Paste the token and click **Sign in**

Print the token again at any time:

```bash
make dashboard-token
```

Kind extraPortMappings are applied only when the cluster is created. If `https://127.0.0.1:8443` hits Contour (SSL handshake error) or nothing, the cluster was created before this mapping existed. Recreate it:

```bash
make down && make up WITH_DASHBOARD=1
```

Fallback port-forward (only if the Kind mapping is missing):

```bash
make dashboard-proxy
```

### Why not http:// or port 443?

| Attempt | Result |
|---------|--------|
| `http://127.0.0.1:8443` | Login fails with an invalid token. Dashboard allows token login only over HTTPS. |
| `https://127.0.0.1:443` | Contour TLS (main ingress), not the dashboard. |
| Ingress through Contour on `:80` | That path is HTTP. Token login would fail. |

Use [https://127.0.0.1:8443](https://127.0.0.1:8443) after `make dashboard`.

### What you can see after login

- **Workloads** in `k8s-local` (echo-proxy, if installed), `temporal` (if installed), `kubernetes-dashboard`, and `projectcontour`
- Pod logs and describe views
- CPU/memory once metrics-server is scraping (may take a minute after install)
- Cluster objects (nodes, namespaces, events)

The default namespace dropdown may show `default`. Switch it to `k8s-local` or **All namespaces** to see echo-proxy.

## Accessing services

### Through Contour (ingress)

Contour listens on localhost **80** (HTTP) and **443** (TLS). It routes by hostname from `config.env` (`INGRESS_HOST`). Use the `Host` header or add an `/etc/hosts` entry:

```text
127.0.0.1 mastrogiovanni.ddns.net
```

```bash
curl -H "Host: mastrogiovanni.ddns.net" http://127.0.0.1/echo-proxy
# or
curl http://mastrogiovanni.ddns.net/echo-proxy
curl https://mastrogiovanni.ddns.net/echo-proxy
```

Change the hostname in [`config.env`](config.env) and re-apply platform plus the app: `make platform` then `make -C ../echo-proxy up`. To override once: `make platform INGRESS_HOST=echo.local`.

### Port mappings

Kind maps Envoy's node ports to localhost (see `cluster/cluster.yaml`):

| Kind node port | Localhost | Use |
|----------------|-----------|-----|
| 80             | 80        | Contour HTTP (apps such as echo-proxy) |
| 443            | 443       | Contour TLS |
| 30443          | 8443      | Kubernetes Dashboard HTTPS (`make dashboard`) |

Kind maps 80/443 on all host interfaces (`0.0.0.0`) so router port-forwards and Let's Encrypt HTTP-01 can reach Contour. Dashboard `:8443` stays on `127.0.0.1`. Temporal UI is `https://mastrogiovanni.ddns.net/temporal` after `make up` in `../temporal`.

If `kind create cluster` fails because 80 or 443 is already in use, stop the other process (or another local web server) and retry. Changing these mappings requires recreating the Kind cluster.

## Kind and Contour notes

### LoadBalancer shows `<pending>`

This is expected on Kind. Kind has no cloud load balancer integration. Contour's Envoy DaemonSet binds directly to the node via `hostPort`, so ingress works through the Kind port mappings above — not through the `envoy` Service external IP.

### Local images in Kind

echo-proxy uses a locally built image (`echo-app:kind`) with `imagePullPolicy: Never`. Kind cannot pull images from your Docker daemon; they must be loaded explicitly from that directory:

```bash
cd ../echo-proxy && make image   # build + kind load docker-image
```

## TLS (Let's Encrypt)

`make platform` / `make up` stay HTTP-only. TLS is a second step so a missing secret cannot invalidate the HTTPProxy.

The existing files are:

| File | Role |
|------|------|
| `platform/cert/cluster-issuer.yaml` | Let's Encrypt production ClusterIssuer (HTTP-01, Ingress class `contour`) |
| `platform/cert/certificate.yaml` | Asks cert-manager for `echo-app-tls` on `INGRESS_HOST` |
| `platform/cert/kustomization.yaml` | Applies issuer + certificate |

Do **not** put `tls.secretName` on `ingress-root` until the secret exists. Contour marks the HTTPProxy invalid otherwise, and HTTP breaks too. `make cert` attaches TLS only after `echo-app-tls` is Ready.

### 1. Public HTTP-01 (required)

Let's Encrypt must reach `http://mastrogiovanni.ddns.net/.well-known/acme-challenge/...` on **TCP/80**. That means:

1. Set a real inbox in `config.env`:
   ```bash
   ACME_EMAIL=you@example.com
   ```
2. Recreate Kind so ingress listens on all interfaces (`cluster/cluster.yaml` uses `listenAddress: "0.0.0.0"`):
   ```bash
   make down && make up
   ```
3. On the router, forward **TCP 80 and 443** to this machine (`192.168.1.102`).
4. Confirm from **outside** the LAN (phone off Wi-Fi, or a VPS):
   ```bash
   curl -I http://mastrogiovanni.ddns.net/echo-proxy
   ```
   You should reach Contour (and echo-proxy if it is deployed). If port 80 is not reachable from the public internet, ACME will fail.

From inside the LAN, opening the public hostname often fails (NAT hairpin). Use `/etc/hosts` for local browsers:

```text
127.0.0.1 mastrogiovanni.ddns.net
```

### 2. Issue the cert and attach it

```bash
make cert
```

That will:

1. Install cert-manager
2. Apply the ClusterIssuer + Certificate (`__INGRESS_HOST__` and `__ACME_EMAIL__` are substituted from `config.env`)
3. Wait until `echo-app-cert` is Ready
4. Attach `echo-app-tls` to HTTPProxy `ingress-root`

Then:

```bash
cd ../echo-proxy && make up
curl https://mastrogiovanni.ddns.net/echo-proxy
```

### 3. If `make cert` times out

```bash
kubectl get certificate,challenge -n k8s-local --context kind-k8s
kubectl describe challenge -n k8s-local --context kind-k8s
```

Typical cause: Let's Encrypt still cannot reach port 80 on the public IP.

For local HTTP testing only, skip this section.

## HTTP Basic Auth (contour-authserver)

Architecture, request flow, objects, and threat model: [`AUTH.md`](AUTH.md).

Contour does not implement a login form itself. [contour-authserver](https://github.com/projectcontour/contour-authserver) sits behind Envoy as an external authorization service and challenges the browser with **HTTP Basic Auth**. One gate on `ingress-root` protects every included app (`/sprar`, `/temporal`, `/echo-proxy`).

Contour only allows this on a **TLS** virtual host. Install TLS first, then auth:

```bash
make cert
make auth
```

`make auth` will:

1. Install cert-manager (needed for contour-authserver's own serving certificate)
2. Deploy contour-authserver in namespace `projectcontour-auth`
3. Bind it to `ingress-root` via an `ExtensionService`
4. Create a first user (`admin`) with a random password if the `passwords` secret does not exist yet, and print it once

The browser then shows its native username/password dialog. `curl` uses `-u`:

```bash
curl -u 'admin:PASSWORD' https://mastrogiovanni.ddns.net/sprar/
```

HTTP on port 80 is redirected to HTTPS once TLS is attached; the Basic Auth prompt appears on HTTPS.

### Username and password

Users are **not** in git. They live in the Kubernetes Secret `projectcontour-auth/passwords`:

- key `auth`: Apache htpasswd file (`username:hashed-password` per line)
- annotation `projectcontour.io/auth-type: basic` (required so contour-authserver loads the secret)

Do not put plaintext passwords in the Secret; store hashes. The Makefile does that for you.

Create or reset a user (omit `AUTH_PASS` to generate a random password and print it once):

```bash
make auth-user AUTH_USER=alice
make auth-user AUTH_USER=alice AUTH_PASS='choose-a-password'
```

List or revoke:

```bash
make auth-users
make auth-user-delete AUTH_USER=alice
```

Use `AUTH_USER` / `AUTH_PASS`, not `USER` / `PASSWORD`. `USER` is already your OS login name, so `make auth-user USER=alice` would not do what you expect.

Give someone access by sending them the username, the password, and the URL (`https://mastrogiovanni.ddns.net/sprar`). The same credentials work for every UI on this host.

contour-authserver watches the Secret, so adding a user takes effect without restarting the auth pod.

To stop requiring a password without deleting users:

```bash
make auth-off
```

Re-run `make auth` (or `make ingress-root`) to attach it again.

### Manual htpasswd (optional)

If you want to edit the file yourself instead of `make auth-user`:

```bash
htpasswd -nbB alice 'choose-a-password' > /tmp/auth
kubectl create secret generic passwords -n projectcontour-auth \
  --from-file=auth=/tmp/auth --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret passwords -n projectcontour-auth \
  projectcontour.io/auth-type=basic --overwrite
rm /tmp/auth
```

`htpasswd -nbB` writes a bcrypt hash. If `htpasswd` is missing, `make auth-user` falls back to `openssl passwd -apr1` or Apache SHA.

## Troubleshooting

**Empty reply from curl**

- Confirm you are hitting localhost `:80`, not `:8080`
- Confirm the `Host` header matches `INGRESS_HOST` in `config.env`
- Confirm the HTTPProxy is applied: `kubectl get httpproxy -n k8s-local --context kind-k8s`
- Confirm echo-proxy is deployed: `cd ../echo-proxy && make up`
- Confirm echo pods are running: `kubectl get pods -n k8s-local --context kind-k8s`
- If the HTTPProxy status is `invalid`, check for missing TLS secrets or cert-manager resources
- If the cluster was created before the 80/443 mappings, recreate it: `make down && make up`

**Kind fails to bind port 80 or 443**

- Something else on the host is using that port (`ss -lntp | grep -E ':80|:443'`)
- Stop the other listener and recreate the cluster if create already failed

**Image changes not reflected after echo-proxy `make up`**

- Ensure the rollout completed: `kubectl rollout status deployment/echo-app -n k8s-local --context kind-k8s`
- Use `make redeploy` in `../echo-proxy` for a faster edit-build-test loop

**Image pull errors**

- Rebuild and load from `../echo-proxy`: `make image`
- The deployment expects `imagePullPolicy: Never` and a preloaded `echo-app:kind` image

**cert-manager / Let's Encrypt errors**

- Do not add TLS to `ingress-root` until the secret exists. Use `make cert`, which attaches TLS only after `echo-app-tls` exists
- `make cert` requires `ACME_EMAIL` in `config.env`
- HTTP-01 needs public TCP/80 to this machine. Kind 80/443 mappings apply only at cluster create; after changing `cluster/cluster.yaml`, run `make down && make up`
- `make platform` does not install cert-manager or certificates

**HTTP Basic Auth is not prompting / HTTPProxy is invalid**

- Contour only attaches external auth when `ingress-root` has TLS. Run `make cert`, then `make auth`
- Confirm: `make auth-status`
- Confirm the HTTPProxy is valid: `kubectl get httpproxy ingress-root -n k8s-local --context kind-k8s`
- Confirm the auth pod is ready: `kubectl get pods -n projectcontour-auth --context kind-k8s`
- Users are in `kubectl get secret passwords -n projectcontour-auth --context kind-k8s`
- Create a user: `make auth-user AUTH_USER=alice`

**401 Unauthorized after typing the password**

- Recreate the user (passwords are hashed; they cannot be recovered): `make auth-user AUTH_USER=alice`
- Confirm the Secret has the annotation: `kubectl get secret passwords -n projectcontour-auth -o yaml --context kind-k8s`

**Temporal Helm install fails**

- Use [`../temporal`](../temporal): `cd ../temporal && make up`

**Dashboard login shows invalid token**

- You must use `https://127.0.0.1:8443`, not `http://`
- Get a fresh token: `make dashboard-token`
- Confirm the admin user exists: `kubectl get sa,secret,clusterrolebinding -n kubernetes-dashboard --context kind-k8s`

**`https://localhost:8443` shows an SSL error or the echo app**

- The current Kind cluster still maps `8443` to Contour (old config). Recreate: `make down && make up WITH_DASHBOARD=1`
- Confirm Docker published ports include `127.0.0.1:8443->30443/tcp`

**Browser refuses the dashboard certificate**

- Expected. Kong presents a self-signed certificate. Use Advanced → Proceed / Accept
- Do not switch the URL to HTTP; token login will then fail

**`make dashboard-proxy` fails with address already in use**

- Kind already maps localhost `8443` to the dashboard; you do not need a port-forward
- Do not use `443`; Kind already maps that port to Contour TLS

**Dashboard pods not ready / Helm install fails**

- Helm 3 must be on your `PATH`
- The original Helm repo `https://kubernetes.github.io/dashboard/` returns 404 after the project was archived. This repo uses `https://kubernetes-retired.github.io/dashboard/`
- Confirm pods: `kubectl get pods -n kubernetes-dashboard --context kind-k8s`
- Re-run `make dashboard`; `helm upgrade --install` is idempotent

**No CPU/memory graphs in the dashboard**

- Wait a minute after install for metrics-server to scrape Kind kubelets
- Confirm metrics-server is running: `kubectl get pods -A --context kind-k8s | grep metrics-server`
- Kind requires `--kubelet-insecure-tls`; that flag is set in `dashboard/values.yaml`

**GPU pod stays Pending (`Insufficient nvidia.com/gpu`)**

- Recreate the cluster with GPU support: `make down && make up WITH_GPU=1`
- Confirm allocatable GPUs: `make gpu-status`
- Confirm the device plugin is running: `kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds --context kind-k8s`
- On the host, `make gpu-prereqs` must pass before cluster create

**CUDA / nvidia-smi fails inside a GPU pod**

- Host toolkit paths may differ from `cluster/cluster.gpu.yaml` — adjust `extraMounts` and recreate Kind
- Confirm `runtimeClassName: nvidia` on the workload (sprar baidu overlay sets this)
- Test Docker GPU access: `docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu22.04 nvidia-smi`

## kubectl context

All Makefile targets use context `kind-k8s` (the default context Kind creates for cluster name `k8s`).

```bash
kubectl config use-context kind-k8s
```
