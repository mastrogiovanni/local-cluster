#!/usr/bin/env bash
# Verify host NVIDIA driver + Docker GPU access before creating a GPU Kind cluster.
set -euo pipefail

NVIDIA_RUNTIME_CONFIG="/etc/nvidia-container-runtime/config.toml"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi not found. Install the NVIDIA driver on the host." >&2
  exit 1
fi

if ! nvidia-smi -L >/dev/null 2>&1; then
  echo "nvidia-smi failed. Check the NVIDIA driver." >&2
  exit 1
fi

for path in /usr/bin/nvidia-container-runtime /usr/bin/nvidia-container-cli; do
  if [ ! -e "$path" ]; then
    echo "Missing $path — install NVIDIA Container Toolkit:" >&2
    echo "  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html" >&2
    exit 1
  fi
done

if [ -f "$NVIDIA_RUNTIME_CONFIG" ]; then
  if ! grep -Eq '^\s*accept-nvidia-visible-devices-as-volume-mounts\s*=\s*true' "$NVIDIA_RUNTIME_CONFIG"; then
    echo "Kind GPU requires volume-mount mode in $NVIDIA_RUNTIME_CONFIG:" >&2
    echo "  accept-nvidia-visible-devices-as-volume-mounts = true" >&2
    echo "Enable it with:" >&2
    echo "  sudo nvidia-ctk config --set accept-nvidia-visible-devices-as-volume-mounts=true --in-place" >&2
    echo "  sudo systemctl restart docker" >&2
    exit 1
  fi
else
  echo "Warning: $NVIDIA_RUNTIME_CONFIG not found; skipping volume-mount config check." >&2
fi

if ! docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
  echo "Docker cannot access GPUs (--gpus all test failed)." >&2
  echo "Configure the NVIDIA Container Toolkit for Docker and restart docker:" >&2
  echo "  sudo nvidia-ctk runtime configure --runtime=docker" >&2
  echo "  sudo systemctl restart docker" >&2
  exit 1
fi

# Kind nodes are Docker containers; this is the injection pattern they rely on.
if ! docker run --rm \
  -v /dev/null:/var/run/nvidia-container-devices/all \
  --gpus all nvidia/cuda:12.6.0-base-ubuntu22.04 nvidia-smi -L >/dev/null 2>&1; then
  echo "Kind GPU volume-mount test failed." >&2
  echo "Ensure accept-nvidia-visible-devices-as-volume-mounts = true, then restart docker." >&2
  exit 1
fi

echo "GPU prerequisites OK ($(nvidia-smi -L | wc -l | tr -d ' ') GPU(s) visible to Docker)."
