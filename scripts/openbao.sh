#!/usr/bin/env bash
# Initialise and unseal the shared OpenBao (standalone mode).
# Keys are written to KEYS_DIR/init.json (mode 600): one unseal key, one root token.
# usage: openbao.sh init|unseal|status|token CONTEXT NS KEYS_DIR
set -euo pipefail

op=$1 ctx=$2 ns=$3 keys_dir=$4
pod=openbao-0
keys_file="$keys_dir/init.json"

bao() {
	kubectl exec -i "$pod" -n "$ns" --context "$ctx" -c openbao -- bao "$@"
}

json_field() {
	python3 -c 'import json,sys; d=json.load(sys.stdin); v=d
for k in sys.argv[1].split("."):
    v = v[int(k)] if isinstance(v, list) else v[k]
print(str(v).lower() if isinstance(v, bool) else v)' "$1"
}

status_json() {
	# `bao status` exits 2 when sealed; the JSON is still printed.
	bao status -format=json 2>/dev/null || true
}

wait_running() {
	kubectl wait --for=jsonpath='{.status.phase}'=Running pod/"$pod" -n "$ns" --context "$ctx" --timeout=180s >/dev/null
	for _ in $(seq 1 30); do
		[ -n "$(status_json)" ] && return 0
		sleep 2
	done
	echo "OpenBao in $ns/$pod does not answer" >&2
	exit 1
}

do_init() {
	wait_running
	if [ "$(status_json | json_field initialized)" = "true" ]; then
		return 0
	fi
	if [ -s "$keys_file" ]; then
		echo "OpenBao is uninitialised but $keys_file exists (old cluster?)." >&2
		echo "Move it away to re-initialise: mv $keys_file $keys_file.old" >&2
		exit 1
	fi
	mkdir -p "$keys_dir"
	chmod 700 "$keys_dir"
	umask 077
	bao operator init -key-shares=1 -key-threshold=1 -format=json >"$keys_file.tmp"
	mv "$keys_file.tmp" "$keys_file"
	echo "OpenBao initialised; unseal key and root token saved to $keys_file"
}

do_unseal() {
	wait_running
	if [ "$(status_json | json_field sealed)" = "false" ]; then
		echo "OpenBao is unsealed"
		return 0
	fi
	[ -s "$keys_file" ] || { echo "Missing $keys_file; cannot unseal" >&2; exit 1; }
	key="$(json_field unseal_keys_b64.0 <"$keys_file")"
	bao operator unseal "$key" >/dev/null
	echo "OpenBao unsealed"
}

case "$op" in
	init) do_init; do_unseal ;;
	unseal) do_unseal ;;
	status) bao status || true ;;
	token)
		[ -s "$keys_file" ] || { echo "Missing $keys_file" >&2; exit 1; }
		json_field root_token <"$keys_file"
		;;
	*) echo "usage: openbao.sh init|unseal|status|token CONTEXT NS KEYS_DIR" >&2; exit 2 ;;
esac
