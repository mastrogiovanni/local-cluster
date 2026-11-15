#!/usr/bin/env bash
# Ensure Secret NAME in NS has KEY. A non-empty VALUE (from config.toml) is always applied;
# an empty VALUE generates a random one only if the key does not exist yet.
# usage: ensure-secret.sh CONTEXT NS NAME KEY [VALUE]
set -euo pipefail

ctx=$1 ns=$2 name=$3 key=$4 value=${5-}

current="$(kubectl get secret "$name" -n "$ns" --context "$ctx" -o "jsonpath={.data.${key//./\\.}}" 2>/dev/null || true)"

if [ -z "$value" ]; then
	if [ -n "$current" ]; then
		exit 0
	fi
	value="$(openssl rand -hex 24)"
	echo "Generated $key for secret $ns/$name (see: make services-info)"
fi

kubectl create secret generic "$name" -n "$ns" --context "$ctx" \
	--from-literal="$key=$value" --dry-run=client -o yaml \
	| kubectl apply -f - --context "$ctx" >/dev/null
