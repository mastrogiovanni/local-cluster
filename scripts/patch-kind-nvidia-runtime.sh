#!/usr/bin/env bash
# Copy NVIDIA Container Toolkit binaries/libs missing from a running Kind node.
# Bind-mounted files from cluster.gpu.yaml are skipped (device or resource busy).
set -euo pipefail

KIND_CLUSTER="${KIND_CLUSTER:-k8s}"
NODE="${KIND_CLUSTER}-control-plane"

if ! docker inspect "$NODE" >/dev/null 2>&1; then
  echo "Kind node $NODE not found; skip runtime patch." >&2
  exit 0
fi

copy_if_missing() {
  local src="$1" dst="$2"
  if [ ! -e "$src" ]; then
    return 0
  fi
  if docker exec "$NODE" test -e "$dst" 2>/dev/null; then
    echo "  skip $dst (already present)"
    return 0
  fi
  if docker cp "$src" "$NODE:$dst"; then
    echo "  patched $dst"
  else
    echo "  warn: could not patch $dst" >&2
  fi
}

echo "Patching NVIDIA runtime files into $NODE..."
docker exec "$NODE" mkdir -p /usr/bin /usr/lib/x86_64-linux-gnu

for src in /usr/bin/nvidia-*; do
  [ -e "$src" ] || continue
  copy_if_missing "$src" "/usr/bin/$(basename "$src")"
done

for lib in /usr/lib/x86_64-linux-gnu/libnvidia*.so*; do
  [ -e "$lib" ] || continue
  copy_if_missing "$lib" "/usr/lib/x86_64-linux-gnu/$(basename "$lib")"
done

echo "NVIDIA runtime patch complete."
