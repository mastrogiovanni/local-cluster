#!/bin/bash
# Create, list, or delete HTTP Basic Auth users stored in an htpasswd Secret.
set -euo pipefail

usage() {
	echo "usage: htpasswd-user.sh add|delete|list CONTEXT NS SECRET USER [PASSWORD]" >&2
	exit 2
}

if [ "$#" -lt 4 ]; then
	usage
fi

op=$1
ctx=$2
ns=$3
secret=$4
user=${5-}
password=${6-}

if [ "$op" != "list" ] && [ -z "$user" ]; then
	echo "username is required" >&2
	exit 2
fi

if [ -n "$user" ] && [[ "$user" == *:* ]]; then
	echo "username must not contain ':'" >&2
	exit 2
fi

hash_password() {
	local name=$1 pass=$2
	if command -v htpasswd >/dev/null 2>&1; then
		htpasswd -niB "$name" <<<"$pass"
	elif command -v openssl >/dev/null 2>&1; then
		printf '%s:%s\n' "$name" "$(openssl passwd -apr1 -stdin <<<"$pass")"
	else
		python3 -c 'import base64, hashlib, sys
user, password = sys.argv[1], sys.argv[2]
digest = base64.b64encode(hashlib.sha1(password.encode("utf-8")).digest()).decode("ascii")
print(f"{user}:{{SHA}}{digest}")
' "$name" "$pass"
	fi
}

read_auth() {
	if kubectl get secret "$secret" -n "$ns" --context "$ctx" >/dev/null 2>&1; then
		kubectl get secret "$secret" -n "$ns" --context "$ctx" -o jsonpath='{.data.auth}' | base64 -d
		echo
	fi
}

write_auth() {
	local tmp
	tmp=$(mktemp)
	awk 'NF' >"$tmp"
	kubectl create secret generic "$secret" -n "$ns" --context "$ctx" \
		--from-file=auth="$tmp" --dry-run=client -o yaml \
		| kubectl apply -f - --context "$ctx" >/dev/null
	kubectl annotate secret "$secret" -n "$ns" --context "$ctx" \
		projectcontour.io/auth-type=basic --overwrite >/dev/null
	rm -f "$tmp"
}

filter_user() {
	local name=$1
	awk -F: -v u="$name" '$1 != u { print }'
}

case "$op" in
	list)
		auth=$(read_auth)
		if [ -z "$(printf '%s' "$auth" | tr -d '[:space:]')" ]; then
			echo "(no users)"
			exit 0
		fi
		printf '%s\n' "$auth" | awk -F: 'NF && $1 !~ /^#/ { print $1 }'
		;;
	add)
		if [ -z "$password" ]; then
			echo "password is required" >&2
			exit 2
		fi
		line=$(hash_password "$user" "$password")
		{
			read_auth | filter_user "$user"
			printf '%s\n' "$line"
		} | write_auth
		echo "user ${user} saved in secret ${ns}/${secret}"
		;;
	delete)
		auth=$(read_auth)
		if ! printf '%s\n' "$auth" | awk -F: -v u="$user" '$1 == u { found=1 } END { exit !found }'; then
			echo "user ${user} not found in secret ${ns}/${secret}" >&2
			exit 1
		fi
		printf '%s\n' "$auth" | filter_user "$user" | write_auth
		echo "user ${user} removed from secret ${ns}/${secret}"
		;;
	*)
		usage
		;;
esac
