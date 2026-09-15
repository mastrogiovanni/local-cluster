KIND_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))
KIND_DIR := $(abspath $(dir $(KIND_MAKEFILE)))
BASE_DIR := $(abspath $(KIND_DIR)/..)
KUBE_CONTEXT := kind-k8s
NAMESPACE := k8s-local
KIND_CLUSTER := k8s

-include $(KIND_DIR)/config.env
INGRESS_HOST ?= echo.example.com
ACME_EMAIL ?=
CERT_MANAGER_VERSION := v1.17.2
CERT_MANAGER_MANIFEST := https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.yaml

KUSTOMIZE_PATH := $(KIND_DIR)/platform
ECHO_PROXY_DIR := $(abspath $(KIND_DIR)/../echo-proxy)
TEMPORAL_DIR := $(abspath $(KIND_DIR)/../temporal)
SPRAR_DIR := $(abspath $(KIND_DIR)/../../sprar)
DATA_PLANE_DIR := $(abspath $(KIND_DIR)/../../data-plane)
TLS_SECRET := echo-app-tls
INGRESS_ROOT := ingress-root
AUTH_SCRIPT := $(KIND_DIR)/scripts/httpproxy-auth.sh
HTPASSWD_SCRIPT := $(KIND_DIR)/scripts/htpasswd-user.sh
AUTH_DIR := $(KIND_DIR)/platform/auth
AUTH_NS := projectcontour-auth
AUTH_NAME := htpasswd
AUTH_SECRET := passwords
AUTH_USER ?=
AUTH_PASS ?=
WITH_AUTH ?= 0

DASHBOARD_NS := kubernetes-dashboard
DASHBOARD_DIR := $(KIND_DIR)/dashboard
DASHBOARD_LOCAL_PORT := 8443
DASHBOARD_PROXY_SVC := kubernetes-dashboard-kong-proxy
WITH_DASHBOARD ?= 0
WITH_GPU ?= 0
GPU_DIR := $(KIND_DIR)/platform/gpu
GPU_PREREQ_SCRIPT := $(KIND_DIR)/scripts/check-gpu-prereqs.sh
GPU_BUILD_SCRIPT := $(KIND_DIR)/scripts/build-gpu-device-plugin.sh
GPU_DETECT_SCRIPT := $(KIND_DIR)/scripts/detect-gpu-device.sh
GPU_PATCH_SCRIPT := $(KIND_DIR)/scripts/patch-kind-nvidia-runtime.sh
GPU_CONFIGURE_SCRIPT := $(KIND_DIR)/scripts/configure-kind-gpu-device.sh
GPU_DEVICE_PLUGIN_IMAGE ?= localhost/k8s-device-plugin:v0.17.0

.PHONY: cluster
cluster:
	@mkdir -p $(DATA_PLANE_DIR)
	@if [ "$(WITH_GPU)" = "1" ]; then \
		$(GPU_PREREQ_SCRIPT); \
	fi
	@if kind get clusters | grep -qx $(KIND_CLUSTER); then \
		echo "Cluster $(KIND_CLUSTER) already exists (host 80/443 mappings, data-plane extraMounts, and GPU settings apply only at create; use make down && make up to recreate)"; \
	else \
		cfg=$$(mktemp); \
		if [ "$(WITH_GPU)" = "1" ]; then \
			cluster_tpl=$(KIND_DIR)/cluster/cluster.gpu.yaml; \
		else \
			cluster_tpl=$(KIND_DIR)/cluster/cluster.yaml; \
		fi; \
		sed -e "s|__DATA_PLANE_HOST__|$(DATA_PLANE_DIR)|g" \
		    -e "s|__SPRAR_HOST__|$(SPRAR_DIR)|g" \
		    $$cluster_tpl >$$cfg; \
		if [ "$(WITH_GPU)" = "1" ]; then \
			chmod +x $(GPU_DETECT_SCRIPT); \
			gpu_uuid="$${GPU_DEVICE_UUID:-$$($(GPU_DETECT_SCRIPT))}"; \
			echo "Creating Kind with NVIDIA_VISIBLE_DEVICES=$$gpu_uuid"; \
			NVIDIA_VISIBLE_DEVICES="$$gpu_uuid" kind create cluster --name $(KIND_CLUSTER) --config $$cfg; \
		else \
			kind create cluster --name $(KIND_CLUSTER) --config $$cfg; \
		fi; \
		rm -f $$cfg; \
	fi

define apply-kustomize
	kubectl kustomize $(1) | sed \
		-e "s/__INGRESS_HOST__/$(INGRESS_HOST)/g" \
		-e "s/__ACME_EMAIL__/$(ACME_EMAIL)/g" \
		| kubectl apply -f - --context $(KUBE_CONTEXT)
endef

.PHONY: cert-manager
cert-manager:
	kubectl apply -f $(CERT_MANAGER_MANIFEST) --context $(KUBE_CONTEXT)
	kubectl wait --for=condition=Available deployment --all -n cert-manager --context $(KUBE_CONTEXT) --timeout=180s

.PHONY: cert
cert: cert-manager
	@if [ -z "$(ACME_EMAIL)" ] || [ "$(ACME_EMAIL)" = "admin@example.com" ]; then \
		echo "Set ACME_EMAIL in config.env to a real address, then re-run make cert"; \
		exit 1; \
	fi
	$(call apply-kustomize,$(KUSTOMIZE_PATH)/cert)
	@echo "Waiting for Let's Encrypt to issue $(INGRESS_HOST) (HTTP-01 needs public TCP/80)..."
	@if ! kubectl wait --for=condition=Ready certificate/echo-app-cert -n $(NAMESPACE) --context $(KUBE_CONTEXT) --timeout=300s; then \
		echo; \
		echo "Certificate was not issued. HTTP-01 only works if $(INGRESS_HOST) reaches this machine on port 80."; \
		kubectl get certificate,certificaterequest,order,challenge -n $(NAMESPACE) --context $(KUBE_CONTEXT); \
		exit 1; \
	fi
	@$(MAKE) ingress-root
	@echo
	@echo "TLS secret $(TLS_SECRET) is ready for $(INGRESS_HOST)."
	@echo "  curl https://$(INGRESS_HOST)/echo-proxy"
	@echo "  curl https://$(INGRESS_HOST)/temporal"
	@echo "  curl https://$(INGRESS_HOST)/sprar"

.PHONY: ingress-root
ingress-root:
	@if kubectl get httpproxy $(INGRESS_ROOT) -n $(NAMESPACE) --context $(KUBE_CONTEXT) >/dev/null 2>&1; then \
		kubectl patch httpproxy $(INGRESS_ROOT) -n $(NAMESPACE) --context $(KUBE_CONTEXT) --type merge \
			-p '{"spec":{"virtualhost":{"fqdn":"$(INGRESS_HOST)"}}}'; \
	else \
		sed -e "s/__INGRESS_HOST__/$(INGRESS_HOST)/g" $(KUSTOMIZE_PATH)/httpproxy.yaml \
			| kubectl apply -n $(NAMESPACE) -f - --context $(KUBE_CONTEXT); \
	fi
	@if kubectl get secret $(TLS_SECRET) -n $(NAMESPACE) --context $(KUBE_CONTEXT) >/dev/null 2>&1; then \
		kubectl patch httpproxy $(INGRESS_ROOT) -n $(NAMESPACE) --context $(KUBE_CONTEXT) --type merge \
			-p '{"spec":{"virtualhost":{"tls":{"secretName":"$(TLS_SECRET)"}}}}'; \
		echo "Attached $(TLS_SECRET) to HTTPProxy $(INGRESS_ROOT)"; \
	fi
	@if kubectl get extensionservice $(AUTH_NAME) -n $(AUTH_NS) --context $(KUBE_CONTEXT) >/dev/null 2>&1; then \
		$(AUTH_SCRIPT) enable $(KUBE_CONTEXT) $(NAMESPACE) $(INGRESS_ROOT) $(AUTH_NS) $(AUTH_NAME) $(TLS_SECRET); \
	fi

.PHONY: platform
platform:
	kubectl apply -f https://projectcontour.io/quickstart/contour.yaml --context $(KUBE_CONTEXT)
	$(call apply-kustomize,$(KUSTOMIZE_PATH))
	$(MAKE) ingress-root
	@echo
	@echo "Cluster basics are up. Ingress host: $(INGRESS_HOST)"
	@echo "Deploy apps from their own directories, e.g.:"
	@echo "  $(MAKE) -C $(ECHO_PROXY_DIR) up"
	@echo "  $(MAKE) -C $(TEMPORAL_DIR) up"
	@echo "  $(MAKE) -C $(SPRAR_DIR) up"
	@echo "  $(MAKE) -C $(SPRAR_DIR) up OCR=baidu   # needs make up WITH_GPU=1 here first"
	@echo "  curl -H \"Host: $(INGRESS_HOST)\" http://127.0.0.1/echo-proxy"
	@echo "  curl https://$(INGRESS_HOST)/temporal"
	@echo "  curl https://$(INGRESS_HOST)/sprar"

.PHONY: gpu-prereqs gpu-image gpu gpu-status
gpu-prereqs:
	@$(GPU_PREREQ_SCRIPT)

gpu-image:
	@chmod +x $(GPU_BUILD_SCRIPT)
	@KIND_CLUSTER=$(KIND_CLUSTER) GPU_DEVICE_PLUGIN_IMAGE=$(GPU_DEVICE_PLUGIN_IMAGE) $(GPU_BUILD_SCRIPT)

gpu: gpu-prereqs gpu-image
	@chmod +x $(GPU_DETECT_SCRIPT) $(GPU_PATCH_SCRIPT) $(GPU_CONFIGURE_SCRIPT)
	@KIND_CLUSTER=$(KIND_CLUSTER) KUBE_CONTEXT=$(KUBE_CONTEXT) $(GPU_PATCH_SCRIPT)
	@GPU_DEVICE_UUID="$(GPU_DEVICE_UUID)" KIND_CLUSTER=$(KIND_CLUSTER) KUBE_CONTEXT=$(KUBE_CONTEXT) $(GPU_CONFIGURE_SCRIPT)
	@GPU_DEVICE_UUID="$(GPU_DEVICE_UUID)" gpu_uuid="$$($(GPU_DETECT_SCRIPT))"; \
	echo "Using GPU UUID: $$gpu_uuid"; \
	kubectl kustomize $(GPU_DIR) \
		| sed -e "s|__GPU_DEVICE_UUID__|$$gpu_uuid|g" \
		| kubectl apply -f - --context $(KUBE_CONTEXT)
	@echo "Waiting for NVIDIA device plugin..."
	@kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n kube-system --context $(KUBE_CONTEXT) --timeout=180s
	@$(MAKE) gpu-status

gpu-status:
	@echo "Allocatable GPUs per node:"
	@kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu --context $(KUBE_CONTEXT)

.PHONY: up
up: cluster platform
	@if [ "$(WITH_GPU)" = "1" ]; then \
		$(MAKE) gpu; \
	fi
	@if [ "$(WITH_DASHBOARD)" = "1" ]; then \
		$(MAKE) dashboard; \
	fi
	@if [ "$(WITH_AUTH)" = "1" ]; then \
		$(MAKE) auth; \
	fi

.PHONY: auth
auth: cert-manager
	kubectl apply -f $(AUTH_DIR)/selfsigned-issuer.yaml --context $(KUBE_CONTEXT)
	kubectl apply -k $(AUTH_DIR) --context $(KUBE_CONTEXT)
	@echo "Waiting for contour-authserver TLS certificate..."
	kubectl wait --for=condition=Ready certificate/htpasswd -n $(AUTH_NS) --context $(KUBE_CONTEXT) --timeout=90s
	kubectl rollout status deployment/htpasswd -n $(AUTH_NS) --context $(KUBE_CONTEXT) --timeout=120s
	@if ! kubectl get secret $(AUTH_SECRET) -n $(AUTH_NS) --context $(KUBE_CONTEXT) >/dev/null 2>&1; then \
		u="$(AUTH_USER)"; \
		[ -n "$$u" ] || u=admin; \
		p="$(AUTH_PASS)"; \
		generated=0; \
		if [ -z "$$p" ]; then p="$$(openssl rand -base64 18)"; generated=1; fi; \
		$(HTPASSWD_SCRIPT) add $(KUBE_CONTEXT) $(AUTH_NS) $(AUTH_SECRET) "$$u" "$$p"; \
		echo; \
		echo "========== HTTP Basic Auth =========="; \
		echo "Created first user in secret $(AUTH_NS)/$(AUTH_SECRET)"; \
		echo "Username: $$u"; \
		if [ "$$generated" = "1" ]; then \
			echo "Password: $$p"; \
			echo "This password is shown once. Reset with: make auth-user AUTH_USER=$$u"; \
		else \
			echo "Password: (the AUTH_PASS you passed)"; \
		fi; \
		echo "====================================="; \
	fi
	@$(MAKE) ingress-root
	@echo
	@$(AUTH_SCRIPT) status $(KUBE_CONTEXT) $(NAMESPACE) $(INGRESS_ROOT) $(AUTH_NS) $(AUTH_NAME) $(TLS_SECRET)
	@echo
	@echo "Users:  make auth-users"
	@echo "Add:    make auth-user AUTH_USER=alice"
	@echo "Delete: make auth-user-delete AUTH_USER=alice"
	@echo "Off:    make auth-off"

.PHONY: auth-user
auth-user:
	@if [ -z "$(AUTH_USER)" ]; then \
		echo "Set AUTH_USER, e.g. make auth-user AUTH_USER=alice"; \
		echo "Optional: AUTH_PASS=secret (a random password is generated if omitted)"; \
		exit 1; \
	fi
	@kubectl get extensionservice $(AUTH_NAME) -n $(AUTH_NS) --context $(KUBE_CONTEXT) >/dev/null 2>&1 || { \
		echo "contour-authserver is not installed. Run make auth first."; \
		exit 1; \
	}
	@p="$(AUTH_PASS)"; \
	generated=0; \
	if [ -z "$$p" ]; then p="$$(openssl rand -base64 18)"; generated=1; fi; \
	$(HTPASSWD_SCRIPT) add $(KUBE_CONTEXT) $(AUTH_NS) $(AUTH_SECRET) "$(AUTH_USER)" "$$p"; \
	echo; \
	echo "Username: $(AUTH_USER)"; \
	if [ "$$generated" = "1" ]; then \
		echo "Password: $$p"; \
	else \
		echo "Password: (the AUTH_PASS you passed)"; \
	fi; \
	echo "Browser: https://$(INGRESS_HOST)/sprar"; \
	echo "curl:    curl -u '$(AUTH_USER):PASSWORD' https://$(INGRESS_HOST)/sprar/"

.PHONY: auth-user-delete
auth-user-delete:
	@if [ -z "$(AUTH_USER)" ]; then \
		echo "Set AUTH_USER, e.g. make auth-user-delete AUTH_USER=alice"; \
		exit 1; \
	fi
	@$(HTPASSWD_SCRIPT) delete $(KUBE_CONTEXT) $(AUTH_NS) $(AUTH_SECRET) "$(AUTH_USER)"

.PHONY: auth-users
auth-users:
	@$(HTPASSWD_SCRIPT) list $(KUBE_CONTEXT) $(AUTH_NS) $(AUTH_SECRET)

.PHONY: auth-off
auth-off:
	@$(AUTH_SCRIPT) disable $(KUBE_CONTEXT) $(NAMESPACE) $(INGRESS_ROOT) $(AUTH_NS) $(AUTH_NAME) $(TLS_SECRET)

.PHONY: auth-status
auth-status:
	@$(AUTH_SCRIPT) status $(KUBE_CONTEXT) $(NAMESPACE) $(INGRESS_ROOT) $(AUTH_NS) $(AUTH_NAME) $(TLS_SECRET)

.PHONY: dashboard
dashboard:
	@command -v helm >/dev/null || { echo "helm is required to install the Kubernetes Dashboard"; exit 1; }
	helm repo add kubernetes-dashboard https://kubernetes-retired.github.io/dashboard/ --force-update
	helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
		--namespace $(DASHBOARD_NS) \
		--create-namespace \
		-f $(DASHBOARD_DIR)/values.yaml \
		--timeout 300s \
		--wait \
		--kube-context $(KUBE_CONTEXT)
	kubectl apply -k $(DASHBOARD_DIR) --context $(KUBE_CONTEXT)
	@echo "Waiting for the admin-user token secret..."
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		token="$$(kubectl get secret admin-user -n $(DASHBOARD_NS) --context $(KUBE_CONTEXT) -o jsonpath='{.data.token}' 2>/dev/null)"; \
		if [ -n "$$token" ]; then break; fi; \
		sleep 2; \
	done
	@echo
	@echo "Kubernetes Dashboard is installed."
	@echo "URL:    https://127.0.0.1:$(DASHBOARD_LOCAL_PORT)"
	@echo "Open:   make dashboard-open"
	@echo "Token:  make dashboard-token"

.PHONY: dashboard-token
dashboard-token:
	@kubectl get secret admin-user -n $(DASHBOARD_NS) --context $(KUBE_CONTEXT) -o jsonpath='{.data.token}' | base64 -d
	@echo

.PHONY: dashboard-proxy
dashboard-proxy:
	@echo "Dashboard is mapped by Kind to https://127.0.0.1:$(DASHBOARD_LOCAL_PORT)"
	@echo "This target is only needed if that mapping is missing."
	@echo "Login with the bearer token from: make dashboard-token"
	@echo "Accept the self-signed certificate warning in the browser."
	@echo "Stop with Ctrl+C."
	kubectl port-forward -n $(DASHBOARD_NS) svc/$(DASHBOARD_PROXY_SVC) $(DASHBOARD_LOCAL_PORT):443 --context $(KUBE_CONTEXT)

.PHONY: dashboard-ui
dashboard-ui: dashboard-open
dashboard-open:
	@kubectl get svc $(DASHBOARD_PROXY_SVC) -n $(DASHBOARD_NS) --context $(KUBE_CONTEXT) >/dev/null 2>&1 || $(MAKE) dashboard
	@echo
	@echo "========== Kubernetes Dashboard =========="
	@echo "URL:   https://127.0.0.1:$(DASHBOARD_LOCAL_PORT)"
	@echo "Login: paste the token below into 'Enter token', then Sign in."
	@echo "The browser will warn about a self-signed certificate; proceed anyway."
	@echo "=========================================="
	@echo
	@token="$$(kubectl get secret admin-user -n $(DASHBOARD_NS) --context $(KUBE_CONTEXT) -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)"; \
	printf '%s\n' "$$token"; \
	echo; \
	if command -v pbcopy >/dev/null; then \
		printf '%s' "$$token" | pbcopy; \
		echo "Token copied to the clipboard."; \
	elif command -v xclip >/dev/null; then \
		printf '%s' "$$token" | xclip -selection clipboard; \
		echo "Token copied to the clipboard."; \
	elif command -v wl-copy >/dev/null; then \
		printf '%s' "$$token" | wl-copy; \
		echo "Token copied to the clipboard."; \
	fi
	@echo
	@if command -v open >/dev/null; then open "https://127.0.0.1:$(DASHBOARD_LOCAL_PORT)"; \
	elif command -v xdg-open >/dev/null; then xdg-open "https://127.0.0.1:$(DASHBOARD_LOCAL_PORT)"; \
	fi

.PHONY: down
down:
	kind delete cluster --name $(KIND_CLUSTER)
