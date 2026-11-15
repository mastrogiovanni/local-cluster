# k8s-local

Local Kubernetes development environment using [Kind](https://kind.sigs.k8s.io/) and [Contour](https://projectcontour.io/) ingress.

`make up` brings up the **platform only**: Kind, Contour, the `k8s-local` namespace, a shared Contour `ingress-root` HTTPProxy, and whatever `config.toml` enables (GPU, TLS, HTTP Basic Auth, Kubernetes Dashboard, shared PostgreSQL / Redis / NATS / OpenBao).

The control plane knows nothing about applications. Each app owns its manifests and deploys itself onto the platform; see [Deploying apps](#deploying-apps).

## Architecture

```
host :80 / :443  (Kind extraPortMappings on 0.0.0.0)
    │
    ▼
Contour Envoy (hostPort 80/443)
    │
    ▼
HTTPProxy ingress-root (INGRESS_HOST; TLS when [ingress] tls = true)
    │  HTTP Basic Auth when [auth] enabled (TLS required)
    ├── /.contour-ready  →  200 ok (built-in health route)
    └── /<prefix>        →  include registered by each app
```

Apps register path includes on `ingress-root`. After they are deployed, Contour forwards those prefixes on `INGRESS_HOST`.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm 3](https://helm.sh/docs/intro/install/) (required for the Kubernetes Dashboard)
- Python 3.11+ (reads `config.toml`)
- Localhost ports **80** and **443** must be free (Kind binds Contour there)

For GPU workloads (optional), you also need:

- NVIDIA driver (`nvidia-smi` works on the host)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) configured for Docker
- A quick sanity check: `docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu22.04 nvidia-smi`

## Configuration

Everything `make up` does is driven by [`config.toml`](config.toml). Flip `enabled` on a section and re-run `make up`:

| Section | What it controls |
|---------|------------------|
| `[cluster]` | Kind cluster name, `k8s-local` namespace, host `data-plane` dir and extra `mounts` |
| `[ingress]` | `host` for `ingress-root`; `tls = true` makes `make up` issue and attach a certificate, `tls_issuer` picks Let's Encrypt (`acme_email`), staging, or self-signed ([TLS](#tls)) |
| `[gpu]` | `enabled`, `device_id` (UUID `GPU-…` or `nvidia-smi` index such as `"1"`), `match` (name regex used when `device_id` is empty) |
| `[dashboard]` | Kubernetes Dashboard + metrics-server |
| `[auth]` | HTTP Basic Auth on `ingress-root` (needs `ingress.tls`), first `user` |
| `[services.postgres]` `[services.redis]` `[services.nats]` `[services.openbao]` | Shared services in the `k8s-services` namespace ([below](#shared-services)) |
| `[env]` | Extra `KEY = "value"` pairs written to `config.env` for app Makefiles |

Missing keys fall back to the defaults in [`scripts/config.py`](scripts/config.py); `make config` prints the effective configuration (secrets masked). Every `make` run renders it into:

- `.config.mk` (git-ignored), included by this Makefile;
- [`config.env`](config.env): **generated** `KEY=VALUE` file that apps include to learn `INGRESS_HOST`, `ACME_EMAIL`, `TLS_SECRET`, `GPU_DEVICE_UUID` and the `[env]` extras. Edit `config.toml` instead.

Command-line variables still override the file for a single run, and another file can be used whole:

```bash
make up INGRESS_HOST=k8s.local WITH_GPU=1
make up K8S_CONFIG=/path/to/other.toml
```

`scripts/config.py` needs Python 3.11+ (`tomllib`).

Add the host to `/etc/hosts` if you want to open it in a browser without a `Host` header:

```text
127.0.0.1 mastrogiovanni.ddns.net
```

Kind extraPortMappings and the `data-plane` extraMount are applied only when the cluster is created. After changing `cluster/cluster.yaml` or `cluster/cluster.gpu.yaml` (including the localhost 80/443 mappings, GPU mounts, or the host data directory), recreate the cluster with `make down && make up`.

## Quick start

From this directory, after enabling what you need in `config.toml`:

```bash
make up
```

`make up` will, in order:

1. Create the Kind cluster (GPU variant when `gpu.enabled`)
2. Install Contour, the `k8s-local` namespace, and `ingress-root`
3. `make gpu`, `make tls`, `make dashboard`, `make auth`, for each one enabled
4. `make services`: the enabled shared services

Then deploy apps from their own directories.

### GPU-enabled cluster (optional)

For workloads that request `nvidia.com/gpu`, recreate the cluster with GPU support and install the NVIDIA device plugin:

Set `[gpu] enabled = true` (and pick the card with `device_id`), then:

```bash
make down
make up
make gpu-status
```

`gpu.enabled` uses `cluster/cluster.gpu.yaml` (NVIDIA runtime in containerd + host toolkit mounts). The device plugin is applied automatically during `make up`.

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

`cluster/cluster.gpu.yaml` mounts `/dev/null` at `/var/run/nvidia-container-devices/all` inside the Kind node (the host does **not** need `/var/run/nvidia-container-devices`). If toolkit binaries live outside `/usr/bin`, adjust `extraMounts` before `make down && make up`.

On hosts with **multiple GPUs**, only the GPU selected by `[gpu] device_id` is exposed to Kind (`nvidia-smi -L` lists UUIDs and indices; with `device_id` empty, the first GPU whose name matches `match` is used, default `RTX 4060`). The UUID is passed as `NVIDIA_VISIBLE_DEVICES` to `kind create` and to the device plugin; `scripts/configure-kind-gpu-device.sh` (run by `make gpu`) checks the node sees that GPU. `make gpu-status` should show **GPU: 1**. Changing the GPU requires `make down && make up`.

Check Contour answers on the configured host:

```bash
curl -H "Host: mastrogiovanni.ddns.net" http://127.0.0.1/.contour-ready   # → ok
```

Tear down the cluster:

```bash
make down
```

## Makefile targets

| Target | Description |
|--------|-------------|
| `make up` | Create cluster, platform, then everything enabled in `config.toml` |
| `make up INGRESS_HOST=... WITH_DASHBOARD=1` | Same, overriding `config.toml` values for one run |
| `make config` | Print the effective configuration (defaults + `config.toml`) |
| `make services` / `make services-down` | Deploy enabled shared services / remove all of them (PVCs and Secrets kept) |
| `make services-info` | Print in-cluster URLs and credentials of deployed services |
| `make postgres` `redis` `nats` `openbao` | Deploy one service (also when disabled in the file) |
| `make <svc>-forward` | Port-forward a service to localhost (ports from `local_port`) |
| `make postgres-psql` / `make redis-cli` | Open a client inside the pod |
| `make openbao-unseal` / `openbao-status` / `openbao-token` | OpenBao helpers (standalone mode) |
| `make down` | Delete the Kind cluster |
| `make cluster` | Create the Kind cluster only |
| `make platform` | Install Contour, apply Kustomize manifests, ensure ingress-root |
| `make ingress-root` | Create or update the shared Contour HTTPProxy (preserves app includes) |
| `make cert-manager` | Install cert-manager in the Kind cluster |
| `make tls` (alias `make cert`) | Install cert-manager, issue the certificate from `[ingress] tls_issuer`, attach TLS to ingress-root (run by `make up` when `tls = true`) |
| `make auth` | Install contour-authserver and require HTTP Basic Auth on TLS ingress |
| `make auth-user AUTH_USER=...` | Create or update an HTTP Basic user (random password if `AUTH_PASS` is omitted) |
| `make auth-users` | List HTTP Basic usernames |
| `make auth-user-delete AUTH_USER=...` | Remove an HTTP Basic user |
| `make auth-off` / `make auth-status` | Detach auth from ingress-root, or print whether it is attached |
| `make dashboard` | Install the Kubernetes Dashboard, metrics-server, and admin login user |
| `make dashboard-token` | Print the admin bearer token used to sign in |
| `make dashboard-proxy` | Port-forward Kong to `:8443` if the Kind mapping is missing |
| `make dashboard-open` / `make dashboard-ui` | Install if needed, print/copy the token, and open `https://127.0.0.1:8443` |

## Project layout

Apps are not part of this tree.

```
.
├── Makefile                 # Cluster basics automation
├── AUTH.md                  # Ingress HTTP Basic Auth architecture
├── config.toml              # The configuration (features, GPU, TLS, services)
├── config.env               # GENERATED from config.toml for app Makefiles
├── services/                # Shared service manifests ({{ key }} filled from config.toml)
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
│   ├── config.py            # config.toml loader/renderer (defaults live here)
│   ├── ensure-secret.sh     # Create service Secrets (random value if not configured)
│   ├── openbao.sh           # OpenBao init / unseal / token
│   ├── httpproxy-include.sh # Add/remove app path includes on ingress-root
│   ├── httpproxy-auth.sh    # Attach/detach HTTP Basic Auth on ingress-root
│   └── htpasswd-user.sh     # Create/list/delete htpasswd users
└── dashboard/
    ├── kustomization.yaml
    ├── values.yaml          # Dashboard Helm values (Kind)
    └── admin-user.yaml      # Admin ServiceAccount + token
```

## Shared services

Enable any of these under `[services.*]` in `config.toml`. They run as single-replica StatefulSets in the `k8s-services` namespace (`services.namespace`), with data on PVCs (Kind's `standard` local-path class), and are reachable from any namespace:

| Service | In-cluster address | Credentials (Secret in `k8s-services`) |
|---------|--------------------|-----------------------------------------|
| PostgreSQL | `postgres.k8s-services.svc.cluster.local:5432` | `postgres` / key `password` |
| Redis | `redis.k8s-services.svc.cluster.local:6379` | `redis` / key `password` |
| NATS (+ JetStream) | `nats.k8s-services.svc.cluster.local:4222`, monitor `:8222` | `nats` / key `token` |
| OpenBao | `http://openbao.k8s-services.svc.cluster.local:8200` | root token: `make openbao-token` |

`make services-info` prints full connection URLs. Passwords/tokens left empty in `config.toml` are generated once and never rotated; a value set in the file is applied on every `make <service>` (restart the pod to pick it up). `services.postgres.databases` lists extra databases created idempotently.

**OpenBao** has two modes (`services.openbao.mode`):

- `standalone` (default): file storage on a PVC. The first `make openbao` initialises it with one unseal key and saves the key and root token to `<data_plane_dir>/control-plane/openbao/init.json` (mode 600). Every later `make openbao` / `make up` only unseals it; run `make openbao-unseal` after the pod restarts. Back that file up: without it the data cannot be unsealed.
- `dev`: in-memory and always unsealed; data is lost on every restart.

To wipe a service's data: `make <service>-down`, then delete its PVC (`kubectl get pvc -n k8s-services --context kind-k8s`). `kubectl delete ns k8s-services` wipes all of them. `make down` removes everything except the OpenBao key file on the host.

## Deploying apps

Apps live outside this directory, each with its own manifests and Makefile; the control plane never references them. An app plugs into the platform through this contract:

| Platform provides | How an app uses it |
|-------------------|--------------------|
| Kube context `kind-<cluster.name>` (default `kind-k8s`), Kind cluster `<cluster.name>` | `kubectl --context`, `kind load docker-image --name` for local images |
| `config.env` | `-include <k8s>/config.env` in the app Makefile for `INGRESS_HOST`, `TLS_SECRET`, `GPU_DEVICE_UUID`, `[env]` extras |
| HTTPProxy `k8s-local/ingress-root` on `INGRESS_HOST` | Ship a child HTTPProxy (no `virtualhost`), then register its prefix: `scripts/httpproxy-include.sh add <ctx> k8s-local ingress-root <child> <child-ns> /<prefix>` (`remove` on teardown) |
| TLS + Basic Auth on `ingress-root` | Inherited by every include; a route can opt out with `authPolicy: {disabled: true}` |
| Shared services in `k8s-services` | Connect to `postgres` / `redis` / `nats` / `openbao` `.k8s-services.svc.cluster.local`; credentials from `make services-info` |
| `nvidia.com/gpu` + RuntimeClass `nvidia` (when `[gpu] enabled`) | Request `nvidia.com/gpu: 1` and set `runtimeClassName: nvidia` |
| Host `data_plane_dir` mounted at `/data-plane` on the node | hostPath PVs under `/data-plane/<app>`; more host dirs via `[cluster] mounts` |

A minimal app Makefile:

```make
K8S_DIR := ../control-plane/k8s
-include $(K8S_DIR)/config.env

up:
	kubectl apply -k manifests --context kind-k8s
	$(K8S_DIR)/scripts/httpproxy-include.sh add kind-k8s k8s-local ingress-root myapp myapp /myapp

down:
	$(K8S_DIR)/scripts/httpproxy-include.sh remove kind-k8s k8s-local ingress-root myapp myapp /myapp
	kubectl delete -k manifests --context kind-k8s --ignore-not-found
```

## Kubernetes Dashboard

The Kubernetes Dashboard is a web UI for namespaces, workloads, pods, logs and events. The install also enables **metrics-server** for CPU/memory graphs. Kind kubelets use self-signed certs, so metrics-server runs with `--kubelet-insecure-tls`.

The Helm chart (from `https://kubernetes-retired.github.io/dashboard/`, values in `dashboard/values.yaml`) puts a **Kong** gateway in front of the Dashboard. Kong is the only entry point. It terminates HTTPS with a self-signed certificate and routes to the web UI, API and auth backends. Only Kong's proxy is enabled (no Kong Manager / admin API). Kind maps Kong's NodePort `30443` to **`127.0.0.1:8443`** on the host. Contour keeps `80`/`443`.

```
Browser ──https──► 127.0.0.1:8443 ──Kind port mapping──► NodePort 30443
                                                             │
                                          kubernetes-dashboard-kong-proxy:443  (Kong, self-signed TLS)
                                                             │
                              ┌──────────────────────────────┼──────────────────────────────┐
                              ▼                              ▼                              ▼
                       dashboard-web                  dashboard-api                  dashboard-auth
```

### Enable

In `config.toml`:

```toml
[dashboard]
enabled = true
```

Then run `make up`, or `make dashboard` on a running cluster. This installs the Helm release in namespace `kubernetes-dashboard`, plus metrics-server. It also creates an `admin-user` ServiceAccount bound to `cluster-admin` with a long-lived token Secret. `cluster-admin` is fine for this local cluster only; do not copy this to a shared one.

### Open and sign in

```bash
make dashboard-open    # installs if missing, prints + copies the token, opens the browser
```

1. Go to **[https://127.0.0.1:8443](https://127.0.0.1:8443)**. It must be `https`; `http://` gets a `400` from Kong.
2. Accept the self-signed certificate warning:
   - Chrome: **Advanced → Proceed to 127.0.0.1** (or type `thisisunsafe` on the warning page)
   - Firefox: **Advanced → Accept the Risk and Continue**
   - Safari: **Show Details → visit this website**
3. Choose **Token**, paste the token, then click **Sign in**.

`make dashboard-token` prints the token again. It does not expire, because it comes from the `admin-user` Secret. The token is copied to the clipboard when `pbcopy`, `xclip` or `wl-copy` is installed.

Pick **All namespaces** in the namespace selector to see every workload. CPU/memory graphs appear a minute or so after metrics-server starts.

### From another machine

Port `8443` is bound to `127.0.0.1` on purpose: the token is cluster-admin. Do not expose it on the LAN or through `ingress-root`. Tunnel over SSH instead:

```bash
ssh -N -L 8443:127.0.0.1:8443 user@this-host
# then browse https://127.0.0.1:8443 on the remote machine
```

### Without the Kind port mapping

Clusters created before the `30443 → 127.0.0.1:8443` mapping existed don't have it. Kind mappings only apply when the cluster is created. Check with `docker port k8s-control-plane`, which should list `30443/tcp -> 127.0.0.1:8443`. Either recreate the cluster (`make down && make up`) or port-forward Kong directly:

```bash
make dashboard-proxy   # kubectl port-forward svc/kubernetes-dashboard-kong-proxy 8443:443
```

### Check it from the CLI

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:8443/                 # 200: Kong + web UI
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:8443/api/v1/namespace \
  -H "Authorization: Bearer $(make -s dashboard-token)"                            # 200: token accepted
kubectl get pods,svc -n kubernetes-dashboard --context kind-k8s
```

### Common problems

| Symptom | Cause / fix |
|---------|-------------|
| "Invalid token" or login loops | Page opened over `http://`. Token login only works over HTTPS. |
| `https://127.0.0.1:443` shows something else | That's Contour (main ingress), not the Dashboard. Use `:8443`. |
| SSL handshake error or connection refused on `:8443` | Port mapping is missing (see above) or Kong is not ready: `kubectl get pods -n kubernetes-dashboard --context kind-k8s` |
| Empty token | Token Secret not populated yet. Re-run `make dashboard`. |
| No CPU/memory graphs | metrics-server is still starting: `kubectl top nodes --context kind-k8s` |

## Accessing services

### Through Contour (ingress)

Contour listens on localhost **80** (HTTP) and **443** (TLS). It routes by hostname from `config.toml` (`[ingress] host`). Use the `Host` header or add an `/etc/hosts` entry:

```text
127.0.0.1 mastrogiovanni.ddns.net
```

```bash
curl -H "Host: mastrogiovanni.ddns.net" http://127.0.0.1/.contour-ready
# or
curl http://mastrogiovanni.ddns.net/.contour-ready
curl https://mastrogiovanni.ddns.net/.contour-ready
```

Change `[ingress] host` in [`config.toml`](config.toml) and re-run `make up` (the included app routes are preserved). To override once: `make platform INGRESS_HOST=k8s.local`.

### Port mappings

Kind maps Envoy's node ports to localhost (see `cluster/cluster.yaml`):

| Kind node port | Localhost | Use |
|----------------|-----------|-----|
| 80             | 80        | Contour HTTP |
| 443            | 443       | Contour TLS |
| 30443          | 8443      | Kubernetes Dashboard HTTPS (`make dashboard`) |

Kind maps 80/443 on all host interfaces (`0.0.0.0`) so router port-forwards and Let's Encrypt HTTP-01 can reach Contour. Dashboard `:8443` stays on `127.0.0.1`.

If `kind create cluster` fails because 80 or 443 is already in use, stop the other process (or another local web server) and retry. Changing these mappings requires recreating the Kind cluster.

## Kind and Contour notes

### LoadBalancer shows `<pending>`

This is expected on Kind. Kind has no cloud load balancer integration. Contour's Envoy DaemonSet binds directly to the node via `hostPort`, so ingress works through the Kind port mappings above — not through the `envoy` Service external IP.

### Local images in Kind

Kind cannot pull images from your Docker daemon. Apps that use locally built images (`imagePullPolicy: Never`) must load them first: `kind load docker-image <image> --name k8s`.

## TLS

Set it in `config.toml` and run `make up`; there is no separate step:

```toml
[ingress]
host = "mastrogiovanni.ddns.net"
tls = true
tls_issuer = "letsencrypt"          # or "letsencrypt-staging", or "selfsigned"
acme_email = "you@example.com"      # letsencrypt issuers only
```

With `tls = true`, `make up` (after the platform, before auth, services and apps) installs cert-manager, applies the issuer and the `ingress-root` Certificate for `host`, waits until it is Ready, and attaches the `tls_secret` (default `ingress-root-tls`) to `ingress-root` (HTTP then redirects to HTTPS). It is idempotent: on a cluster that already has the certificate it returns immediately. `make tls` runs the same step alone. Changing `host` or `tls_issuer` and re-running `make up` makes cert-manager reissue.

| `tls_issuer` | Use |
|--------------|-----|
| `letsencrypt` | Trusted certificate via HTTP-01; the host must reach this machine on public TCP/80 (below) |
| `letsencrypt-staging` | Same flow, untrusted certificates and generous rate limits, for testing the setup |
| `selfsigned` | No ACME, works offline/LAN-only; browsers warn. Enough to enable HTTP Basic Auth locally |

| File | Role |
|------|------|
| `platform/cert/cluster-issuer.yaml` | Let's Encrypt production + staging ClusterIssuers (HTTP-01, Ingress class `contour`) |
| `platform/cert/certificate.yaml` | Asks cert-manager for `tls_secret` on `[ingress] host` |
| `platform/auth/selfsigned-issuer.yaml` | `selfsigned` ClusterIssuer (also used by the auth server) |

`tls.secretName` is only put on `ingress-root` once the secret exists; Contour marks the HTTPProxy invalid otherwise, and HTTP breaks too.

### 1. Public HTTP-01 (required)

Let's Encrypt must reach `http://mastrogiovanni.ddns.net/.well-known/acme-challenge/...` on **TCP/80**. That means:

1. Set a real inbox in `[ingress] acme_email`.
2. Recreate Kind so ingress listens on all interfaces (`cluster/cluster.yaml` uses `listenAddress: "0.0.0.0"`):
   ```bash
   make down && make up
   ```
3. On the router, forward **TCP 80 and 443** to this machine (`192.168.1.102`).
4. Confirm from **outside** the LAN (phone off Wi-Fi, or a VPS):
   ```bash
   curl -I http://mastrogiovanni.ddns.net/.contour-ready
   ```
   You should reach Contour. If port 80 is not reachable from the public internet, ACME will fail.

From inside the LAN, opening the public hostname often fails (NAT hairpin). Use `/etc/hosts` for local browsers:

```text
127.0.0.1 mastrogiovanni.ddns.net
```

### 2. If the certificate times out

```bash
kubectl get certificate,challenge -n k8s-local --context kind-k8s
kubectl describe challenge -n k8s-local --context kind-k8s
```

Typical cause: Let's Encrypt still cannot reach port 80 on the public IP. For a LAN-only cluster use `tls_issuer = "selfsigned"`, or set `tls = false` for plain HTTP.

## HTTP Basic Auth (contour-authserver)

Architecture, request flow, objects, and threat model: [`AUTH.md`](AUTH.md).

Contour does not implement a login form itself. [contour-authserver](https://github.com/projectcontour/contour-authserver) sits behind Envoy as an external authorization service and challenges the browser with **HTTP Basic Auth**. One gate on `ingress-root` protects every included app route.

Contour only allows this on a **TLS** virtual host, so enable both in `config.toml` and run `make up` (TLS is issued first):

```toml
[ingress]
tls = true

[auth]
enabled = true
```

`make auth` alone works too once TLS is attached.

`make auth` will:

1. Install cert-manager (needed for contour-authserver's own serving certificate)
2. Deploy contour-authserver in namespace `projectcontour-auth`
3. Bind it to `ingress-root` via an `ExtensionService`
4. Create a first user (`admin`) with a random password if the `passwords` secret does not exist yet, and print it once

The browser then shows its native username/password dialog. `curl` uses `-u`:

```bash
curl -u 'admin:PASSWORD' https://mastrogiovanni.ddns.net/<prefix>
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

Give someone access by sending them the username, the password, and the app URL. The same credentials work for every UI on this host.

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
- Confirm the `Host` header matches `[ingress] host` in `config.toml`
- Confirm the HTTPProxy is applied: `kubectl get httpproxy -n k8s-local --context kind-k8s`
- Confirm the app registered its include: `kubectl get httpproxy ingress-root -n k8s-local -o jsonpath='{.spec.includes}' --context kind-k8s`
- If the HTTPProxy status is `invalid`, check for missing TLS secrets or cert-manager resources
- If the cluster was created before the 80/443 mappings, recreate it: `make down && make up`

**Kind fails to bind port 80 or 443**

- Something else on the host is using that port (`ss -lntp | grep -E ':80|:443'`)
- Stop the other listener and recreate the cluster if create already failed

**cert-manager / Let's Encrypt errors**

- Do not add TLS to `ingress-root` until the secret exists. `make tls` attaches TLS only after the secret exists
- Let's Encrypt issuers require `[ingress] acme_email` in `config.toml`
- HTTP-01 needs public TCP/80 to this machine. Kind 80/443 mappings apply only at cluster create; after changing `cluster/cluster.yaml`, run `make down && make up`
- `make platform` does not install cert-manager or certificates

**HTTP Basic Auth is not prompting / HTTPProxy is invalid**

- Contour only attaches external auth when `ingress-root` has TLS. Set `[ingress] tls = true` (or run `make tls`) before `make auth`
- Confirm: `make auth-status`
- Confirm the HTTPProxy is valid: `kubectl get httpproxy ingress-root -n k8s-local --context kind-k8s`
- Confirm the auth pod is ready: `kubectl get pods -n projectcontour-auth --context kind-k8s`
- Users are in `kubectl get secret passwords -n projectcontour-auth --context kind-k8s`
- Create a user: `make auth-user AUTH_USER=alice`

**401 Unauthorized after typing the password**

- Recreate the user (passwords are hashed; they cannot be recovered): `make auth-user AUTH_USER=alice`
- Confirm the Secret has the annotation: `kubectl get secret passwords -n projectcontour-auth -o yaml --context kind-k8s`

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

- Recreate the cluster with GPU support: `set `[gpu] enabled = true`, then `make down && make up``
- Confirm allocatable GPUs: `make gpu-status`
- Confirm the device plugin is running: `kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds --context kind-k8s`
- On the host, `make gpu-prereqs` must pass before cluster create

**CUDA / nvidia-smi fails inside a GPU pod**

- Host toolkit paths may differ from `cluster/cluster.gpu.yaml` — adjust `extraMounts` and recreate Kind
- Confirm the workload sets `runtimeClassName: nvidia` and requests `nvidia.com/gpu`
- Test Docker GPU access: `docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu22.04 nvidia-smi`

## kubectl context

All Makefile targets use context `kind-k8s` (the default context Kind creates for cluster name `k8s`).

```bash
kubectl config use-context kind-k8s
```
