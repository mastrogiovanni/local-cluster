#!/usr/bin/env bash
# Print the UUID of the GPU to expose to Kind.
#   GPU_DEVICE_UUID  explicit UUID (wins)
#   GPU_DEVICE_ID    UUID or nvidia-smi index (from config.toml gpu.device_id)
#   GPU_MATCH        regex on the GPU name, used when neither is set (default: RTX 4060)
set -euo pipefail

if [ -n "${GPU_DEVICE_UUID:-}" ]; then
  printf '%s\n' "$GPU_DEVICE_UUID"
  exit 0
fi

case "${GPU_DEVICE_ID:-}" in
  GPU-*|MIG-*) printf '%s\n' "$GPU_DEVICE_ID"; exit 0 ;;
esac

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi not found" >&2
  exit 1
fi

match="${GPU_MATCH:-RTX 4060}"
while IFS= read -r line; do
  idx="$(printf '%s' "$line" | sed -n 's/^GPU \([0-9]*\):.*/\1/p')"
  uuid="$(printf '%s' "$line" | sed -n 's/.*(UUID: \(GPU-[^)]*\)).*/\1/p')"
  [ -n "$uuid" ] || continue
  if [ -n "${GPU_DEVICE_ID:-}" ]; then
    [ "$idx" = "$GPU_DEVICE_ID" ] && { printf '%s\n' "$uuid"; exit 0; }
  elif printf '%s' "$line" | grep -qiE "$match"; then
    printf '%s\n' "$uuid"
    exit 0
  fi
done < <(nvidia-smi -L)

if [ -n "${GPU_DEVICE_ID:-}" ]; then
  echo "GPU index ${GPU_DEVICE_ID} not found (nvidia-smi -L). Fix gpu.device_id in config.toml." >&2
else
  echo "No GPU matching '${match}' found. Set gpu.device_id in config.toml (nvidia-smi -L)." >&2
fi
exit 1
