#!/bin/bash
# Add or remove a Contour HTTPProxy include on the shared ingress root.
set -euo pipefail

if [ "$#" -ne 7 ]; then
	echo "usage: httpproxy-include.sh add|remove CONTEXT ROOT_NS ROOT_NAME CHILD_NAME CHILD_NS PREFIX" >&2
	exit 2
fi

op=$1
ctx=$2
root_ns=$3
root_name=$4
child_name=$5
child_ns=$6
prefix=$7

if ! kubectl get httpproxy "$root_name" -n "$root_ns" --context "$ctx" >/dev/null 2>&1; then
	echo "HTTPProxy ${root_ns}/${root_name} is missing. Run make platform in k8s/ first." >&2
	exit 1
fi

pairs=$(kubectl get httpproxy "$root_name" -n "$root_ns" --context "$ctx" \
	-o jsonpath='{range .spec.includes[*]}{.name}/{.namespace}{"\n"}{end}')

is_child() {
	[ "$1" = "${child_name}/${child_ns}" ] || [ "$1" = "${child_name}/" ]
}

case "$op" in
	add)
		while IFS= read -r pair; do
			[ -z "$pair" ] && continue
			if is_child "$pair"; then
				echo "include ${child_ns}/${child_name} already present"
				exit 0
			fi
		done <<<"$pairs"
		value=$(printf '{"name":"%s","namespace":"%s","conditions":[{"prefix":"%s"}]}' \
			"$child_name" "$child_ns" "$prefix")
		if [ -z "${pairs//[$'\n']/}" ]; then
			kubectl patch httpproxy "$root_name" -n "$root_ns" --context "$ctx" --type merge \
				-p "{\"spec\":{\"includes\":[${value}]}}"
		else
			kubectl patch httpproxy "$root_name" -n "$root_ns" --context "$ctx" --type json \
				-p "[{\"op\":\"add\",\"path\":\"/spec/includes/-\",\"value\":${value}}]"
		fi
		echo "add include ${child_ns}/${child_name} ${prefix}"
		;;
	remove)
		idx=0
		found=0
		while IFS= read -r pair; do
			[ -z "$pair" ] && continue
			if is_child "$pair"; then
				kubectl patch httpproxy "$root_name" -n "$root_ns" --context "$ctx" --type json \
					-p "[{\"op\":\"remove\",\"path\":\"/spec/includes/${idx}\"}]"
				found=1
				break
			fi
			idx=$((idx + 1))
		done <<<"$pairs"
		if [ "$found" -eq 1 ]; then
			echo "remove include ${child_ns}/${child_name} ${prefix}"
		else
			echo "include ${child_ns}/${child_name} not present"
		fi
		;;
	*)
		echo "unknown op ${op}" >&2
		exit 2
		;;
esac
