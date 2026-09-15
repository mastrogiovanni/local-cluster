#!/usr/bin/env bash
# Verify the Kind node only exposes the OCR GPU (RTX 4060 family).
# On cluster create, Makefile sets NVIDIA_VISIBLE_DEVICES for kind create.
set -euo pipefail

KIND_CLUSTER="${KIND_CLUSTER:-k8s}"
NODE="${KIND_CLUSTER}-control-plane"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DETECT_SCRIPT="${SCRIPT_DIR}/detect-gpu-device.sh"
CONFIG_ENV="${KIND_DIR}/config.env"

if [ -f "$CONFIG_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_ENV"
  set +a
fi

if ! docker inspect "$NODE" >/dev/null 2>&1; then
  echo "Kind node $NODE not found; skip GPU device check." >&2
  exit 0
fi

chmod +x "$DETECT_SCRIPT"
gpu_uuid="$("$DETECT_SCRIPT")"
echo "Expected OCR GPU for Kind: $gpu_uuid"

if ! docker exec "$NODE" nvidia-smi -L >/dev/null 2>&1; then
  echo "Warning: nvidia-smi not available inside $NODE." >&2
  exit 0
fi

node_gpus="$(docker exec "$NODE" nvidia-smi -L 2>/dev/null || true)"
gpu_count="$(printf '%s\n' "$node_gpus" | grep -c '^GPU ' || true)"

if printf '%s\n' "$node_gpus" | grep -qi 'GTX 1060'; then
  echo "Warning: Kind node $NODE still sees GTX 1060." >&2
  echo "Recreate the cluster so only the RTX 4060 is passed to Kind:" >&2
  echo "  cd $KIND_DIR && make down && make up WITH_GPU=1" >&2
  echo "Until then, sprar Baidu pins NVIDIA_VISIBLE_DEVICES=$gpu_uuid on the pod." >&2
fi

if ! printf '%s\n' "$node_gpus" | grep -qiE 'RTX 4060'; then
  echo "Warning: RTX 4060 family GPU not visible inside $NODE." >&2
  echo "node GPUs:" >&2
  printf '%s\n' "$node_gpus" >&2
  exit 1
fi

if [ "$gpu_count" -gt 1 ]; then
  echo "Warning: Kind node reports $gpu_count GPUs (expected 1). Recreate with make down && make up WITH_GPU=1." >&2
fi

echo "Kind node GPU check OK: $(printf '%s' "$node_gpus" | tr '\n' ' ')"
