#!/usr/bin/env bash
# Print the UUID of the preferred GPU (RTX 4060 / 4060 Ti).
# Override with GPU_DEVICE_UUID in the environment.
set -euo pipefail

if [ -n "${GPU_DEVICE_UUID:-}" ]; then
  printf '%s\n' "$GPU_DEVICE_UUID"
  exit 0
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi not found" >&2
  exit 1
fi

while IFS= read -r line; do
  if echo "$line" | grep -qiE 'RTX 4060'; then
    uuid="$(printf '%s' "$line" | sed -n 's/.*(UUID: \(GPU-[^)]*\)).*/\1/p')"
    if [ -n "$uuid" ]; then
      printf '%s\n' "$uuid"
      exit 0
    fi
  fi
done < <(nvidia-smi -L)

echo "No RTX 4060 GPU found. Set GPU_DEVICE_UUID in config.env." >&2
exit 1
