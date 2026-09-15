#!/bin/bash
# Attach or detach Contour HTTP Basic Auth (contour-authserver) on ingress-root.
set -euo pipefail

if [ "$#" -ne 7 ]; then
	echo "usage: httpproxy-auth.sh enable|disable|status CONTEXT ROOT_NS ROOT_NAME AUTH_NS AUTH_NAME TLS_SECRET" >&2
	exit 2
fi

op=$1
ctx=$2
root_ns=$3
root_name=$4
auth_ns=$5
auth_name=$6
tls_secret=$7

if ! kubectl get httpproxy "$root_name" -n "$root_ns" --context "$ctx" >/dev/null 2>&1; then
	echo "HTTPProxy ${root_ns}/${root_name} is missing. Run make platform in k8s/ first." >&2
	exit 1
fi

has_tls() {
	kubectl get secret "$tls_secret" -n "$root_ns" --context "$ctx" >/dev/null 2>&1
}

has_ext() {
	kubectl get extensionservice "$auth_name" -n "$auth_ns" --context "$ctx" >/dev/null 2>&1
}

auth_attached() {
	name=$(kubectl get httpproxy "$root_name" -n "$root_ns" --context "$ctx" \
		-o jsonpath='{.spec.virtualhost.authorization.extensionRef.name}' 2>/dev/null || true)
	[ "$name" = "$auth_name" ]
}

disable_ready_route_auth() {
	local i=0 prefix
	while true; do
		prefix=$(kubectl get httpproxy "$root_name" -n "$root_ns" --context "$ctx" \
			-o jsonpath="{.spec.routes[$i].conditions[0].prefix}" 2>/dev/null || true)
		[ -z "$prefix" ] && break
		if [ "$prefix" = "/.contour-ready" ]; then
			kubectl patch httpproxy "$root_name" -n "$root_ns" --context "$ctx" --type json \
				-p "[{\"op\":\"add\",\"path\":\"/spec/routes/${i}/authPolicy\",\"value\":{\"disabled\":true}}]" \
				>/dev/null 2>&1 || true
			return 0
		fi
		i=$((i + 1))
	done
}

case "$op" in
	status)
		if auth_attached; then
			echo "HTTP Basic Auth is attached to ${root_ns}/${root_name}"
		else
			echo "HTTP Basic Auth is not attached to ${root_ns}/${root_name}"
		fi
		if has_ext; then
			echo "ExtensionService ${auth_ns}/${auth_name} exists"
		else
			echo "ExtensionService ${auth_ns}/${auth_name} is missing (run make auth)"
		fi
		if has_tls; then
			echo "TLS secret ${root_ns}/${tls_secret} exists"
		else
			echo "TLS secret ${root_ns}/${tls_secret} is missing (run make cert)"
		fi
		;;
	enable)
		if ! has_ext; then
			echo "ExtensionService ${auth_ns}/${auth_name} is missing. Run make auth first." >&2
			exit 1
		fi
		if ! has_tls; then
			echo "TLS secret ${root_ns}/${tls_secret} is missing."
			echo "Contour only enables external auth on TLS virtual hosts. Run make cert, then make auth."
			exit 0
		fi
		kubectl patch httpproxy "$root_name" -n "$root_ns" --context "$ctx" --type merge \
			-p "{\"spec\":{\"virtualhost\":{\"authorization\":{\"failOpen\":false,\"extensionRef\":{\"name\":\"${auth_name}\",\"namespace\":\"${auth_ns}\"}}}}}"
		disable_ready_route_auth
		echo "Attached HTTP Basic Auth (${auth_ns}/${auth_name}) to ${root_ns}/${root_name}"
		;;
	disable)
		if auth_attached; then
			kubectl patch httpproxy "$root_name" -n "$root_ns" --context "$ctx" --type json \
				-p '[{"op":"remove","path":"/spec/virtualhost/authorization"}]'
			echo "Removed HTTP Basic Auth from ${root_ns}/${root_name}"
		else
			echo "HTTP Basic Auth was not attached to ${root_ns}/${root_name}"
		fi
		;;
	*)
		echo "unknown op ${op}" >&2
		exit 2
		;;
esac
