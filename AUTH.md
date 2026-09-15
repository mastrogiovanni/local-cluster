# Ingress HTTP Basic Auth

This cluster does not put login logic in sprar, Temporal, or echo-proxy. A single gate on the shared Contour virtual host (`ingress-root`) asks Envoy to check every HTTPS request with [contour-authserver](https://github.com/projectcontour/contour-authserver) before the request is forwarded to an app.

The challenge is **HTTP Basic Auth**: the browser shows its native username/password dialog; `curl` sends `Authorization: Basic …`. There is no HTML login page and no session cookie.

Operator commands (`make auth`, `make auth-user`, …) live in [README.md](README.md). This document describes how the pieces fit together.

## Goals

- Protect every UI on `INGRESS_HOST` (`/sprar`, `/temporal`, `/echo-proxy`, and future includes) without changing those apps.
- Issue credentials with a Makefile, not an identity provider.
- Keep plaintext passwords out of git. Store hashes in a Kubernetes Secret.
- Fail closed: if the auth server is down, Envoy must not forward the request (`failOpen: false`).

Non-goals: OAuth/OIDC, per-app tokens, user self-registration, SSO across other hosts, protecting HTTP (port 80) as a first-class surface.

## Why this shape

Contour (Envoy) is already the only public entry point. Apps register as HTTPProxy **includes** on `ingress-root`; child proxies have no `virtualhost`, so they cannot attach their own authorizer. Auth therefore belongs on the root virtual host.

Contour does not implement Basic Auth itself. From 1.9 it supports [external authorization](https://projectcontour.io/docs/1.33/guides/external-authorization/): Envoy holds the client request, calls an authorizer over Envoy’s gRPC Check API (v3), and only then forwards to the upstream. [contour-authserver](https://github.com/projectcontour/contour-authserver) is Contour’s reference server for that protocol, with an `htpasswd` backend.

HTTP Basic is the smallest UX that matches “give someone a username and a password.” A custom “paste a token” page would need a cookie-issuing app in front of Envoy. OIDC (oauth2-proxy, Keycloak, Authelia) is heavier than this homelab needs.

Contour will only bind an authorizer to a virtual host that already terminates TLS. That is a Contour constraint, not a local choice. `make cert` must succeed before `make auth` can attach the gate.

## Architecture

```
                          TCP/80                    TCP/443
                             │                          │
                             ▼                          ▼
                    HTTP → 301 HTTPS              TLS (echo-app-tls)
                             │                          │
                             └──────────► Contour Envoy (hostPort on Kind)
                                                │
                     HTTPProxy ingress-root    │
                     fqdn = INGRESS_HOST        │
                     virtualhost.authorization ──┤
                                                │
                         1. hold request        │
                         2. gRPC Check (h2/TLS) ▼
                                    ExtensionService htpasswd
                                    projectcontour-auth:9443
                                                │
                                                ▼
                                    contour-authserver (htpasswd)
                                                │
                              Secret passwords   │  (watch)
                              key: auth          │
                              annotation:       │
                              projectcontour.io/auth-type=basic
                                                │
                         deny ──────────► 401 + WWW-Authenticate: Basic
                         allow ─────────► inject Auth-* headers, continue
                                                │
                                                ▼
                     includes on ingress-root
                     ├── /echo-proxy  → echo-proxy
                     ├── /temporal    → Temporal UI
                     └── /sprar       → sprar
```

Two TLS hops are involved, for different reasons:

| Hop | Secret | Issuer | Purpose |
|-----|--------|--------|---------|
| Browser → Envoy | `k8s-local/echo-app-tls` | Let’s Encrypt (`make cert`) | Public HTTPS for `INGRESS_HOST` |
| Envoy → authserver | `projectcontour-auth/htpasswd` | ClusterIssuer `selfsigned` | Envoy Check API is HTTP/2 over TLS (`protocol: h2`) |

The authserver certificate is not public. Clients never see it. Envoy talks to `htpasswd.projectcontour-auth.svc:9443`. The ExtensionService does not set `spec.validation`, so Envoy does not verify that self-signed cert (same as Contour’s own guide).

## Request flow

### HTTPS document (browser or curl)

1. Kind maps host `:443` to Envoy. SNI and the HTTP `Host` header must be `INGRESS_HOST` (from `config.env`).
2. Contour has programmed this virtual host with `authorization.extensionRef = projectcontour-auth/htpasswd` and `failOpen: false`.
3. Envoy does **not** send the request to the upstream app yet. It opens (or reuses) a gRPC stream to contour-authserver and sends a Check request that includes method, path, and headers (including `Authorization`, if any).
4. contour-authserver looks up htpasswd data it has loaded from Secrets in `projectcontour-auth` annotated `projectcontour.io/auth-type: basic`.
5. **No credentials, or unknown user, or bad password:** Check is denied. Envoy responds to the client with `401` and `WWW-Authenticate: Basic realm="default", charset="UTF-8"`. The body is empty. Apps never see the request.
6. **Valid credentials:** Check is allowed. contour-authserver injects `Auth-Handler`, `Auth-Realm`, and `Auth-Username`. Envoy forwards the original request (still including `Authorization`) to the matched include (`/sprar`, …).

A successful Check is per request. HTTP Basic has no server-side session. The browser caches the pair for this origin (scheme + host + port) and resends it on later requests until the tab/profile forgets it.

### HTTP on port 80

Once `ingress-root` has `tls.secretName`, Contour redirects HTTP to HTTPS (`301`). The Basic Auth challenge is only issued on the HTTPS virtual host. Let’s Encrypt HTTP-01 (`/.well-known/acme-challenge/…`) is a **separate Ingress** created by cert-manager, not a route on `ingress-root`, so the auth gate does not block certificate renewal.

### Paths that skip auth

| Path | Why |
|------|------|
| `/.contour-ready` | Direct response on `ingress-root` with `authPolicy.disabled: true`. Used as a cheap liveness path, not as a public app. |
| ACME HTTP-01 | Different Ingress object; not the HTTPProxy virtual host. |

Child includes cannot opt out. There is no per-app username. One Secret, one realm (`default`), every path under the host.

## Kubernetes objects

Namespace `projectcontour-auth` is dedicated to the authorizer so its RBAC can be scoped. Apps stay in `k8s-local` (and Temporal in `temporal`).

```
projectcontour-auth
├── ServiceAccount htpasswd
├── Role / RoleBinding htpasswd          # get/list/watch Secrets in this namespace only
├── Certificate htpasswd  → Secret htpasswd   (serving TLS for :9443)
├── Deployment htpasswd    contour-authserver:v4
├── Service htpasswd       ClusterIP :9443
└── ExtensionService htpasswd           # Contour → Envoy cluster for Check
    Secret passwords                    # htpasswd file; not in git
```

`k8s-local/ingress-root` is the only HTTPProxy that may set `virtualhost.authorization`. `make ingress-root` (and therefore `make cert` / `make auth`) patches:

```yaml
spec:
  virtualhost:
    fqdn: <INGRESS_HOST>
    tls:
      secretName: echo-app-tls
    authorization:
      failOpen: false
      extensionRef:
        name: htpasswd
        namespace: projectcontour-auth
```

`make auth-off` removes `spec.virtualhost.authorization` only. The Deployment, ExtensionService, and `passwords` Secret stay. Re-run `make auth` or `make ingress-root` to attach again.

Attaching authorization without `tls.secretName` makes Contour mark the HTTPProxy **invalid**, which takes down HTTP as well. Scripts only enable auth when both the TLS secret and the ExtensionService exist.

## Credential store

Users are Apache htpasswd lines in Secret `projectcontour-auth/passwords`:

| Field | Value |
|-------|--------|
| key | `auth` (nginx-compatible) |
| annotation | `projectcontour.io/auth-type: basic` |
| optional annotation | `projectcontour.io/auth-realm` (omit, or `*`, to match realm `default`) |

Each line is `username:hash`. The plaintext password is never stored. `scripts/htpasswd-user.sh` hashes with, in order:

1. `htpasswd -niB` (bcrypt) if Apache `htpasswd` is on `PATH`
2. else `openssl passwd -apr1`
3. else Apache `{SHA}` via Python

contour-authserver is started with `--watch-namespaces=projectcontour-auth`. It runs a controller-runtime watch on Secrets. Adding or deleting a user updates the Secret; the pod does not need a rollout.

The ServiceAccount is bound to a **Role**, not a ClusterRole. Combined with `--watch-namespaces`, the authorizer cannot read Secrets in `k8s-local` or elsewhere.

Bootstrap: if `make auth` finds no `passwords` Secret, it creates user `admin` (override with `AUTH_USER`) and a random password unless `AUTH_PASS` is set. That password is printed once.

Use `AUTH_USER` / `AUTH_PASS` in Make. `USER` is already the OS login name.

## Operator interface

| Command | Effect |
|---------|--------|
| `make auth` | cert-manager, ClusterIssuer `selfsigned`, kustomize `platform/auth`, wait for Certificate + Deployment, maybe bootstrap `admin`, then `make ingress-root` |
| `make auth-user AUTH_USER=alice` | Create or replace that user; random password if `AUTH_PASS` is omitted |
| `make auth-users` | Print usernames only |
| `make auth-user-delete AUTH_USER=alice` | Drop that line from the Secret |
| `make auth-off` | Detach the gate from `ingress-root` |
| `make auth-status` | Whether the HTTPProxy, ExtensionService, and TLS secret are present |
| `make up WITH_AUTH=1` | Platform, then `make auth` (still needs TLS to actually attach) |

Implementation:

- [`platform/auth/`](platform/auth/) — manifests (kustomize namespace `projectcontour-auth`; ClusterIssuer `selfsigned` is applied separately so kustomize does not namespace it)
- [`scripts/httpproxy-auth.sh`](scripts/httpproxy-auth.sh) — enable / disable / status on `ingress-root`
- [`scripts/htpasswd-user.sh`](scripts/htpasswd-user.sh) — mutate the `passwords` Secret

Image: `ghcr.io/projectcontour/contour-authserver:v4`.

## Client behaviour

### curl

A 401 from Basic Auth has **no body**. Without `-i` or `-v`, a missing user looks like an empty response.

```bash
curl -i -u 'alice:the-password-you-set' https://mastrogiovanni.ddns.net/echo-proxy
```

`alice` exists only after `make auth-user AUTH_USER=alice …`. Example passwords in docs are not accounts.

### Browser (native dialog)

For a **top-level navigation** that Envoy answers with `401` + `WWW-Authenticate: Basic`, Chrome/Firefox show a system dialog, not an HTML form. The dialog is attached to the origin (`https://INGRESS_HOST`), so the same pair is reused for `/sprar`, `/temporal`, and `/echo-proxy`.

PWAs that register a service worker may not show the Basic Auth dialog after auth is enabled. See [sprar web README — HTTP Basic Auth](../../sprar/web/README.md#http-basic-auth-contour).

## Trust and threat model

What this provides:

- Random Internet users cannot read the UIs without a pair from `make auth-user`.
- Credentials are hashed at rest in etcd (Kubernetes Secret).
- The authorizer cannot list cluster-wide Secrets.
- Envoy fail-closed if authserver is unavailable.

What this does not provide:

- Per-app authorization (one user can open every include on the host).
- Protection of HTTP except via redirect to HTTPS.
- Phishing-resistant MFA, lockout, or audit of who logged in (only authserver “checking request” logs).
- Confidentiality of the Basic token on the wire beyond TLS. `Authorization: Basic` is Base64, not encryption. Always HTTPS.
- Apps are not required to honor `Auth-Username`. They receive traffic only after Envoy allows it; they may ignore the injected headers.
- The self-signed hop Envoy → authserver is not PKI-verified.

Treat htpasswd users as shared site passwords, not as a directory of people with roles.

## Failure modes

| Symptom | Usual cause |
|---------|------------|
| HTTPProxy `invalid` after enabling auth | `authorization` set but `tls.secretName` missing. `make cert` first. |
| `make auth` deploys pods but no 401 | TLS secret was missing at attach time. `make auth-status`, then `make ingress-root`. |
| 401 with empty body | Expected for unknown/wrong user. Create the user; use `curl -i`. |
| Chrome shows the app with no dialog | PWA service worker installed before auth. Clear site data or use Incognito. |
| 401 after a password you just set | Hash written; secret annotation missing (`projectcontour.io/auth-type=basic`). `htpasswd-user.sh` sets it. |
| Auth pod `CreateContainerConfigError` | Certificate `htpasswd` not Ready; cert-manager / ClusterIssuer `selfsigned` missing. |
| Let’s Encrypt challenge stuck | Unrelated to Basic Auth if HTTP-01 uses its own Ingress. Do not add a `/.well-known` route on `ingress-root`. |

Useful objects:

```bash
kubectl get httpproxy ingress-root -n k8s-local --context kind-k8s
kubectl get extensionservice,deploy,secret -n projectcontour-auth --context kind-k8s
kubectl logs -n projectcontour-auth deploy/htpasswd --context kind-k8s
```

Authserver logs `checking request` with path only; it does not log passwords.

## What we would change later

- **Per-app users:** contour-authserver realms (`--auth-realm` + `projectcontour.io/auth-realm`) or `authPolicy.context` on includes, plus a richer authorizer. Not implemented.
- **Token paste UI:** a small app on `/__auth` that sets a cookie, with the Check endpoint validating the cookie. Contour JWT verification cannot drive a browser login (no `Authorization` header on navigations).
- **OIDC:** same ExtensionService slot; swap contour-authserver’s htpasswd backend for its OIDC module or oauth2-proxy. The HTTPProxy attachment stays.

Until then, the gate is: TLS virtual host → Envoy Check → htpasswd Secret → 401 or the included app.
