#!/usr/bin/env bash
# Build the NVIDIA device plugin image without pulling from nvcr.io (often 403 without NGC login).
set -euo pipefail

IMAGE="${GPU_DEVICE_PLUGIN_IMAGE:-localhost/k8s-device-plugin:v0.17.0}"
TAG="${IMAGE##*:}"
VERSION="${TAG#v}"
KIND_CLUSTER="${KIND_CLUSTER:-k8s}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need docker

cat >/tmp/Dockerfile.k8s-device-plugin <<EOF
FROM golang:1.22-bookworm AS build
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates git \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 --branch v${VERSION} https://github.com/NVIDIA/k8s-device-plugin.git .
# CGO is required for NVML (go-nvml/pkg/dl).
RUN CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" -o /out/nvidia-device-plugin ./cmd/nvidia-device-plugin/

FROM ubuntu:22.04
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/nvidia-device-plugin /usr/bin/nvidia-device-plugin
ENV NVIDIA_DISABLE_REQUIRE=true
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENTRYPOINT ["nvidia-device-plugin"]
EOF

echo "Building container image $IMAGE (CGO enabled)..."
docker build -t "$IMAGE" -f /tmp/Dockerfile.k8s-device-plugin /tmp

if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  echo "Loading $IMAGE into Kind cluster $KIND_CLUSTER..."
  kind load docker-image "$IMAGE" --name "$KIND_CLUSTER"
fi

echo "Device plugin image ready: $IMAGE"
