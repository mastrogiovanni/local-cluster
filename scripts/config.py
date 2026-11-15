#!/usr/bin/env python3
"""Read the control-plane config.toml and expose it to make, shell and manifests.

Usage:
  config.py [-c config.toml] mk              Make variables for the k8s Makefile (.config.mk)
  config.py [-c config.toml] env             KEY=VALUE file for sibling app Makefiles (config.env)
  config.py [-c config.toml] get KEY         Print one value, e.g. services.postgres.image
  config.py [-c config.toml] render FILE     Print FILE with {{ dotted.key }} placeholders filled in
  config.py [-c config.toml] show            Print the effective (defaults + file) config as TOML-ish text

Values not set in config.toml fall back to DEFAULTS below, so a minimal file is enough.
"""

from __future__ import annotations

import argparse
import copy
import re
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    sys.exit("config.py needs Python 3.11+ (tomllib). Install a newer python3.")

K8S_DIR = Path(__file__).resolve().parent.parent

DEFAULTS: dict = {
    "cluster": {
        "name": "k8s",
        "namespace": "k8s-local",
        "data_plane_dir": "../../data-plane",
        # Extra host dirs mounted into the Kind node: [{host = "...", node = "/path"}].
        "mounts": [],
    },
    "ingress": {
        "host": "example.com",
        "acme_email": "",
        "tls": False,
        # "letsencrypt" (HTTP-01, needs public :80), "letsencrypt-staging", or "selfsigned" (local only).
        "tls_issuer": "letsencrypt",
        "tls_secret": "ingress-root-tls",
    },
    "gpu": {
        "enabled": False,
        # UUID ("GPU-...") or nvidia-smi index ("1"). Empty: first GPU whose name matches `match`.
        "device_id": "",
        "match": "RTX 4060",
        "device_plugin_image": "localhost/k8s-device-plugin:v0.17.0",
    },
    "dashboard": {"enabled": False, "local_port": 8443},
    "auth": {"enabled": False, "user": "admin"},
    "services": {
        "namespace": "k8s-services",
        "postgres": {
            "enabled": False,
            "image": "postgres:16-alpine",
            "user": "postgres",
            "database": "postgres",
            "databases": [],
            "password": "",
            "storage": "8Gi",
            "local_port": 5432,
        },
        "redis": {
            "enabled": False,
            "image": "redis:7.4-alpine",
            "password": "",
            "storage": "2Gi",
            "maxmemory": "256mb",
            "local_port": 6379,
        },
        "nats": {
            "enabled": False,
            "image": "nats:2.10-alpine",
            "jetstream": True,
            "storage": "4Gi",
            "token": "",
            "local_port": 4222,
            "monitor_local_port": 8222,
        },
        "openbao": {
            "enabled": False,
            "image": "openbao/openbao:2.2.0",
            # "dev": in-memory, auto-unsealed, data lost on restart.
            # "standalone": file storage on a PVC, initialised/unsealed by `make openbao-init`.
            "mode": "standalone",
            "storage": "1Gi",
            "dev_root_token": "",
            "local_port": 8200,
        },
    },
    "env": {},
}

SERVICE_NAMES = ("postgres", "redis", "nats", "openbao")
NAME_RE = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def merge(base: dict, override: dict, path: str = "") -> dict:
    out = copy.deepcopy(base)
    for key, value in override.items():
        where = f"{path}.{key}" if path else key
        if isinstance(value, dict) and isinstance(out.get(key), dict) and key != "env":
            out[key] = merge(out[key], value, where)
        else:
            out[key] = value
    return out


def fail(msg: str) -> None:
    sys.exit(f"config error: {msg}")


def load(path: Path) -> dict:
    if not path.exists():
        fail(f"{path} not found")
    try:
        data = tomllib.loads(path.read_text())
    except tomllib.TOMLDecodeError as exc:
        fail(f"{path}: {exc}")
    cfg = merge(DEFAULTS, data)

    for section in ("cluster", "ingress", "gpu", "dashboard", "auth", "services"):
        if not isinstance(cfg[section], dict):
            fail(f"[{section}] must be a table")
    unknown = set(cfg["services"]) - set(SERVICE_NAMES) - {"namespace"}
    if unknown:
        fail(f"unknown service(s) {sorted(unknown)}; supported: {', '.join(SERVICE_NAMES)}")
    for key in ("name", "namespace"):
        if not NAME_RE.match(str(cfg["cluster"][key])):
            fail(f"cluster.{key} must be a DNS-1123 label")
    if not NAME_RE.match(str(cfg["services"]["namespace"])):
        fail("services.namespace must be a DNS-1123 label")
    if cfg["services"]["openbao"]["mode"] not in ("dev", "standalone"):
        fail('services.openbao.mode must be "dev" or "standalone"')
    issuers = {"letsencrypt": "letsencrypt-prod", "letsencrypt-staging": "letsencrypt-staging", "selfsigned": "selfsigned"}
    if cfg["ingress"]["tls_issuer"] not in issuers:
        fail(f"ingress.tls_issuer must be one of {', '.join(issuers)}")
    cfg["ingress"]["tls_issuer_ref"] = issuers[cfg["ingress"]["tls_issuer"]]
    if cfg["auth"]["enabled"] and not cfg["ingress"]["tls"]:
        print("config warning: auth.enabled needs ingress.tls (Contour only authenticates TLS vhosts)", file=sys.stderr)

    unknown = set(cfg) - set(DEFAULTS)
    if unknown:
        fail(f"unknown section(s) {sorted(unknown)}; apps are deployed from their own directories")

    for key in cfg["env"]:
        if not ENV_KEY_RE.match(key):
            fail(f"env key {key!r} is not a valid variable name")

    cfg["cluster"]["data_plane_dir"] = str(resolve(cfg["cluster"]["data_plane_dir"]))
    mounts = cfg["cluster"]["mounts"]
    if not isinstance(mounts, list) or not all(isinstance(m, dict) and m.get("host") and m.get("node") for m in mounts):
        fail('cluster.mounts must be a list of {host = "...", node = "/path"} tables')
    cfg["cluster"]["mounts_yaml"] = "".join(
        f"      - hostPath: {resolve(m['host'])}\n        containerPath: {m['node']}\n" for m in mounts
    )
    cfg["cluster"]["kube_context"] = f"kind-{cfg['cluster']['name']}"
    nats = cfg["services"]["nats"]
    nats["jetstream_conf"] = 'jetstream { store_dir: "/data" }' if nats["jetstream"] else ""
    cfg["gpu"]["device_uuid"] = resolve_gpu(str(cfg["gpu"]["device_id"]).strip(), cfg["gpu"]["match"])
    return cfg


def resolve(p: str) -> Path:
    path = Path(p).expanduser()
    return path if path.is_absolute() else (K8S_DIR / path).resolve()


def resolve_gpu(device_id: str, match: str) -> str:
    """Return a GPU UUID for device_id (UUID or index), or '' if it cannot be resolved here."""
    if device_id.startswith(("GPU-", "MIG-")):
        return device_id
    if not shutil.which("nvidia-smi"):
        return ""
    try:
        out = subprocess.run(["nvidia-smi", "-L"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    gpus = re.findall(r"^GPU (\d+): (.*?) \(UUID: (GPU-[^)]+)\)", out, re.M)
    for idx, name, uuid in gpus:
        if device_id and device_id == idx:
            return uuid
        if not device_id and match and re.search(match, name, re.I):
            return uuid
    if device_id:
        fail(f"gpu.device_id {device_id!r} not found in nvidia-smi -L")
    return ""


def lookup(cfg: dict, dotted: str):
    node = cfg
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(dotted)
        node = node[part]
    return node


def scalar(value) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, list):
        return " ".join(str(v) for v in value)
    return str(value)


def yaml_scalar(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def make_escape(value: str) -> str:
    return value.replace("$", "$$").replace("#", "\\#")


def cmd_mk(cfg: dict) -> str:
    c, i, g, s = cfg["cluster"], cfg["ingress"], cfg["gpu"], cfg["services"]
    rows = {
        "KIND_CLUSTER": c["name"],
        "KUBE_CONTEXT": c["kube_context"],
        "NAMESPACE": c["namespace"],
        "DATA_PLANE_DIR": c["data_plane_dir"],
        "INGRESS_HOST": i["host"],
        "ACME_EMAIL": i["acme_email"],
        "TLS_SECRET": i["tls_secret"],
        "WITH_TLS": i["tls"],
        "TLS_ISSUER": i["tls_issuer"],
        "TLS_ISSUER_REF": i["tls_issuer_ref"],
        "WITH_GPU": g["enabled"],
        "GPU_DEVICE_ID": g["device_id"],
        "GPU_DEVICE_UUID": g["device_uuid"],
        "GPU_MATCH": g["match"],
        "GPU_DEVICE_PLUGIN_IMAGE": g["device_plugin_image"],
        "WITH_DASHBOARD": cfg["dashboard"]["enabled"],
        "DASHBOARD_LOCAL_PORT": cfg["dashboard"]["local_port"],
        "WITH_AUTH": cfg["auth"]["enabled"],
        "AUTH_DEFAULT_USER": cfg["auth"]["user"],
        "SERVICES_NS": s["namespace"],
    }
    for name in SERVICE_NAMES:
        svc = s[name]
        rows[f"WITH_{name.upper()}"] = svc["enabled"]
        rows[f"{name.upper()}_LOCAL_PORT"] = svc["local_port"]
    rows["POSTGRES_USER"] = s["postgres"]["user"]
    rows["POSTGRES_DB"] = s["postgres"]["database"]
    rows["POSTGRES_DATABASES"] = s["postgres"]["databases"]
    rows["POSTGRES_PASSWORD_CFG"] = s["postgres"]["password"]
    rows["REDIS_PASSWORD_CFG"] = s["redis"]["password"]
    rows["NATS_TOKEN_CFG"] = s["nats"]["token"]
    rows["NATS_MONITOR_LOCAL_PORT"] = s["nats"]["monitor_local_port"]
    rows["OPENBAO_MODE"] = s["openbao"]["mode"]
    rows["OPENBAO_DEV_ROOT_TOKEN_CFG"] = s["openbao"]["dev_root_token"]

    lines = ["# Generated from config.toml by scripts/config.py; do not edit.",
             "# Command-line variables (make up WITH_GPU=1) still override these."]
    lines += [f"{k} := {make_escape(scalar(v))}" for k, v in rows.items()]
    return "\n".join(lines) + "\n"


def shell_quote(value: str) -> str:
    # config.env is included by Makefiles *and* sourced by bash; stick to values both read the same way.
    if re.search(r"[\s'\"$`\\#]", value):
        fail(f"config.env value {value!r} contains spaces/quotes/$/#, which Make and bash read differently")
    return value


def cmd_env(cfg: dict) -> str:
    rows = {
        "INGRESS_HOST": cfg["ingress"]["host"],
        "ACME_EMAIL": cfg["ingress"]["acme_email"],
        # Secret on ingress-root; apps re-attaching TLS must use this name.
        "TLS_SECRET": cfg["ingress"]["tls_secret"],
    }
    if cfg["gpu"]["device_uuid"]:
        rows["GPU_DEVICE_UUID"] = cfg["gpu"]["device_uuid"]
    rows.update({k: scalar(v) for k, v in cfg["env"].items()})
    lines = [
        "# GENERATED from config.toml by scripts/config.py; edit config.toml instead.",
        "# Read by app Makefiles (-include <k8s>/config.env) and scripts.",
    ]
    lines += [f"{k}={shell_quote(scalar(v))}" for k, v in rows.items()]
    return "\n".join(lines) + "\n"


PLACEHOLDER = re.compile(r"\{\{\s*([A-Za-z0-9_.]+)\s*\}\}")


def cmd_render(cfg: dict, file: Path) -> str:
    def sub(m: re.Match) -> str:
        try:
            return yaml_scalar(lookup(cfg, m.group(1)))
        except KeyError:
            fail(f"{file}: unknown placeholder {{{{ {m.group(1)} }}}}")

    return PLACEHOLDER.sub(sub, file.read_text())


def cmd_show(cfg: dict, prefix: str = "") -> str:
    out = []
    for key, value in cfg.items():
        dotted = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            out.append(cmd_show(value, dotted))
        elif "password" in key or "token" in key:
            out.append(f"{dotted} = {'(set)' if value else '(generated)'}")
        else:
            out.append(f"{dotted} = {value!r}")
    return "\n".join(x for x in out if x)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", "--config", default=str(K8S_DIR / "config.toml"))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("mk")
    sub.add_parser("env")
    sub.add_parser("show")
    g = sub.add_parser("get")
    g.add_argument("key")
    r = sub.add_parser("render")
    r.add_argument("file")
    args = ap.parse_args()

    cfg = load(resolve(args.config))
    if args.cmd == "mk":
        sys.stdout.write(cmd_mk(cfg))
    elif args.cmd == "env":
        sys.stdout.write(cmd_env(cfg))
    elif args.cmd == "show":
        print(cmd_show(cfg))
    elif args.cmd == "get":
        try:
            print(scalar(lookup(cfg, args.key)))
        except KeyError:
            fail(f"unknown key {args.key}")
    elif args.cmd == "render":
        sys.stdout.write(cmd_render(cfg, Path(args.file)))


if __name__ == "__main__":
    main()
