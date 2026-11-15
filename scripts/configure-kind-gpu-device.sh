#!/usr/bin/env bash
# Verify the Kind node only exposes the GPU selected in config.toml ([gpu] device_id / match).
# On cluster create, the Makefile passes NVIDIA_VISIBLE_DEVICES to kind create.
set -euo pipefail

KIND_CLUSTER="${KIND_CLUSTER:-k8s}"
NODE="${KIND_CLUSTER}-control-plane"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DETECT_SCRIPT="${SCRIPT_DIR}/detect-gpu-device.sh"

if ! docker inspect "$NODE" >/dev/null 2>&1; then
  echo "Kind node $NODE not found; skip GPU device check." >&2
  exit 0
fi

gpu_uuid="$("$DETECT_SCRIPT")"
echo "Expected GPU for Kind: $gpu_uuid"

if ! docker exec "$NODE" nvidia-smi -L >/dev/null 2>&1; then
  echo "Warning: nvidia-smi not available inside $NODE." >&2
  exit 0
fi

node_gpus="$(docker exec "$NODE" nvidia-smi -L 2>/dev/null || true)"
gpu_count="$(printf '%s\n' "$node_gpus" | grep -c '^GPU ' || true)"

if ! printf '%s\n' "$node_gpus" | grep -qF "$gpu_uuid"; then
  echo "Selected GPU $gpu_uuid is not visible inside $NODE." >&2
  echo "node GPUs:" >&2
  printf '%s\n' "$node_gpus" >&2
  echo "Recreate the cluster after changing [gpu] in config.toml: cd $KIND_DIR && make down && make up" >&2
  exit 1
fi

if [ "$gpu_count" -gt 1 ]; then
  echo "Warning: Kind node reports $gpu_count GPUs (expected 1). Recreate with make down && make up." >&2
  echo "Until then, GPU workloads may pin NVIDIA_VISIBLE_DEVICES=$gpu_uuid on the pod." >&2
fi

echo "Kind node GPU check OK: $(printf '%s' "$node_gpus" | tr '\n' ' ')"
