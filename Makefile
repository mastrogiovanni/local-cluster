KIND_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))
KIND_DIR := $(abspath $(dir $(KIND_MAKEFILE)))
BASE_DIR := $(abspath $(KIND_DIR)/..)

# All settings come from config.toml (see scripts/config.py for defaults).
# It is rendered on every run into .config.mk (for this Makefile) and config.env (for app Makefiles).
# Use another file with: make up K8S_CONFIG=/path/to/other.toml
K8S_CONFIG ?= $(KIND_DIR)/config.toml
CONFIG_PY := python3 $(KIND_DIR)/scripts/config.py -c $(K8S_CONFIG)
CONFIG_MK := $(KIND_DIR)/.config.mk
CONFIG_ENV := $(KIND_DIR)/config.env
RENDER := $(CONFIG_PY) render
_config_ok := $(shell $(CONFIG_PY) mk >$(CONFIG_MK).tmp && mv $(CONFIG_MK).tmp $(CONFIG_MK) \
	&& $(CONFIG_PY) env >$(CONFIG_ENV).tmp \
	&& { cmp -s $(CONFIG_ENV).tmp $(CONFIG_ENV) && rm -f $(CONFIG_ENV).tmp || mv $(CONFIG_ENV).tmp $(CONFIG_ENV); } \
	&& echo ok)
ifneq ($(_config_ok),ok)
$(error Could not load $(K8S_CONFIG); see the message above)
endif
include $(CONFIG_MK)
CERT_MANAGER_VERSION := v1.17.2
CERT_MANAGER_MANIFEST := https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.yaml

KUSTOMIZE_PATH := $(KIND_DIR)/platform
INGRESS_ROOT := ingress-root
AUTH_SCRIPT := $(KIND_DIR)/scripts/httpproxy-auth.sh
HTPASSWD_SCRIPT := $(KIND_DIR)/scripts/htpasswd-user.sh
AUTH_DIR := $(KIND_DIR)/platform/auth
AUTH_NS := projectcontour-auth
AUTH_NAME := htpasswd
AUTH_SECRET := passwords
AUTH_USER ?=
AUTH_PASS ?=

DASHBOARD_NS := kubernetes-dashboard
DASHBOARD_DIR := $(KIND_DIR)/dashboard
DASHBOARD_PROXY_SVC := kubernetes-dashboard-kong-proxy
GPU_DIR := $(KIND_DIR)/platform/gpu
GPU_PREREQ_SCRIPT := $(KIND_DIR)/scripts/check-gpu-prereqs.sh
GPU_BUILD_SCRIPT := $(KIND_DIR)/scripts/build-gpu-device-plugin.sh
GPU_DETECT_SCRIPT := $(KIND_DIR)/scripts/detect-gpu-device.sh
GPU_PATCH_SCRIPT := $(KIND_DIR)/scripts/patch-kind-nvidia-runtime.sh
GPU_CONFIGURE_SCRIPT := $(KIND_DIR)/scripts/configure-kind-gpu-device.sh
GPU_ENV := GPU_DEVICE_UUID="$(GPU_DEVICE_UUID)" GPU_DEVICE_ID="$(GPU_DEVICE_ID)" GPU_MATCH="$(GPU_MATCH)"

SERVICES_DIR := $(KIND_DIR)/services
ENSURE_SECRET := $(KIND_DIR)/scripts/ensure-secret.sh
OPENBAO_SCRIPT := $(KIND_DIR)/scripts/openbao.sh
OPENBAO_KEYS_DIR := $(DATA_PLANE_DIR)/control-plane/openbao
SVC_KUBECTL := kubectl --context $(KUBE_CONTEXT) -n $(SERVICES_NS)
SERVICES := postgres redis nats openbao
SERVICES_ENABLED := $(foreach s,$(SERVICES),$(if $(filter 1,$(WITH_$(shell echo $(s) | tr a-z A-Z))),$(s)))

.PHONY: config
config:
	@echo "# Effective configuration from $(K8S_CONFIG)"
	@$(CONFIG_PY) show

.PHONY: cluster
cluster:
	@mkdir -p $(DATA_PLANE_DIR)
	@if [ "$(WITH_GPU)" = "1" ]; then \
		$(GPU_PREREQ_SCRIPT); \
	fi
	@if kind get clusters | grep -qx $(KIND_CLUSTER); then \
		echo "Cluster $(KIND_CLUSTER) already exists (host 80/443 mappings, [cluster] mounts, and GPU settings apply only at create; use make down && make up to recreate)"; \
	else \
		cfg=$$(mktemp); \
		if [ "$(WITH_GPU)" = "1" ]; then \
			cluster_tpl=$(KIND_DIR)/cluster/cluster.gpu.yaml; \
		else \
			cluster_tpl=$(KIND_DIR)/cluster/cluster.yaml; \
		fi; \
		$(RENDER) $$cluster_tpl >$$cfg || exit 1; \
		if [ "$(WITH_GPU)" = "1" ]; then \
			chmod +x $(GPU_DETECT_SCRIPT); \
			gpu_uuid="$$($(GPU_ENV) $(GPU_DETECT_SCRIPT))" || exit 1; \
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

# TLS for ingress-root, issuer from [ingress] tls_issuer. Run by `make up` when [ingress] tls = true;
# idempotent: an already-issued certificate returns immediately.
CERT_DIR := $(KUSTOMIZE_PATH)/cert

.PHONY: tls cert
cert: tls
tls: cert-manager
ifneq ($(TLS_ISSUER),selfsigned)
	@if [ -z "$(ACME_EMAIL)" ] || [ "$(ACME_EMAIL)" = "admin@example.com" ]; then \
		echo "Set [ingress] acme_email in config.toml to a real address (or tls_issuer = \"selfsigned\")"; \
		exit 1; \
	fi
	@$(RENDER) $(CERT_DIR)/cluster-issuer.yaml | kubectl apply -f - --context $(KUBE_CONTEXT)
else
	@kubectl apply -f $(AUTH_DIR)/selfsigned-issuer.yaml --context $(KUBE_CONTEXT)
endif
	@$(RENDER) $(CERT_DIR)/certificate.yaml | kubectl apply -f - --context $(KUBE_CONTEXT)
	@echo "Waiting for $(TLS_ISSUER_REF) to issue $(INGRESS_HOST)$(if $(filter selfsigned,$(TLS_ISSUER)),, (HTTP-01 needs public TCP/80))..."
	@if ! kubectl wait --for=condition=Ready certificate/$(INGRESS_ROOT) -n $(NAMESPACE) --context $(KUBE_CONTEXT) --timeout=300s; then \
		echo; \
		echo "Certificate was not issued. HTTP-01 only works if $(INGRESS_HOST) reaches this machine on port 80."; \
		echo "For a local-only cluster set [ingress] tls_issuer = \"selfsigned\"."; \
		kubectl get certificate,certificaterequest,order,challenge -n $(NAMESPACE) --context $(KUBE_CONTEXT); \
		exit 1; \
	fi
	@$(MAKE) ingress-root
	@echo "TLS secret $(TLS_SECRET) is ready: https://$(INGRESS_HOST)/"

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

.PHONY: gpu-prereqs gpu-image gpu gpu-status
gpu-prereqs:
	@$(GPU_PREREQ_SCRIPT)

gpu-image:
	@chmod +x $(GPU_BUILD_SCRIPT)
	@KIND_CLUSTER=$(KIND_CLUSTER) GPU_DEVICE_PLUGIN_IMAGE=$(GPU_DEVICE_PLUGIN_IMAGE) $(GPU_BUILD_SCRIPT)

gpu: gpu-prereqs gpu-image
	@chmod +x $(GPU_DETECT_SCRIPT) $(GPU_PATCH_SCRIPT) $(GPU_CONFIGURE_SCRIPT)
	@KIND_CLUSTER=$(KIND_CLUSTER) KUBE_CONTEXT=$(KUBE_CONTEXT) $(GPU_PATCH_SCRIPT)
	@$(GPU_ENV) KIND_CLUSTER=$(KIND_CLUSTER) KUBE_CONTEXT=$(KUBE_CONTEXT) $(GPU_CONFIGURE_SCRIPT)
	@gpu_uuid="$$($(GPU_ENV) $(GPU_DETECT_SCRIPT))" || exit 1; \
	echo "Using GPU UUID: $$gpu_uuid"; \
	kubectl kustomize $(GPU_DIR) \
		| sed -e "s|__GPU_DEVICE_UUID__|$$gpu_uuid|g" \
		      -e "s|localhost/k8s-device-plugin:v0.17.0|$(GPU_DEVICE_PLUGIN_IMAGE)|g" \
		| kubectl apply -f - --context $(KUBE_CONTEXT)
	@echo "Waiting for NVIDIA device plugin..."
	@kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n kube-system --context $(KUBE_CONTEXT) --timeout=180s
	@$(MAKE) gpu-status

gpu-status:
	@echo "Allocatable GPUs per node:"
	@kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu --context $(KUBE_CONTEXT)

# Everything enabled in config.toml, in dependency order.
.PHONY: up
up: cluster platform
	@if [ "$(WITH_GPU)" = "1" ]; then \
		$(MAKE) gpu; \
	fi
	@if [ "$(WITH_TLS)" = "1" ]; then \
		$(MAKE) cert; \
	fi
	@if [ "$(WITH_DASHBOARD)" = "1" ]; then \
		$(MAKE) dashboard; \
	fi
	@if [ "$(WITH_AUTH)" = "1" ]; then \
		$(MAKE) auth; \
	fi
	@$(MAKE) services
	@echo
	@echo "Control plane is up (config: $(K8S_CONFIG))."
	@echo "  GPU=$(WITH_GPU) TLS=$(WITH_TLS)$(if $(filter 1,$(WITH_TLS)), ($(TLS_ISSUER))) dashboard=$(WITH_DASHBOARD) auth=$(WITH_AUTH)"
	@echo "  services: $(or $(strip $(SERVICES_ENABLED)),none)"

.PHONY: auth
auth: cert-manager
	kubectl apply -f $(AUTH_DIR)/selfsigned-issuer.yaml --context $(KUBE_CONTEXT)
	kubectl apply -k $(AUTH_DIR) --context $(KUBE_CONTEXT)
	@echo "Waiting for contour-authserver TLS certificate..."
	kubectl wait --for=condition=Ready certificate/htpasswd -n $(AUTH_NS) --context $(KUBE_CONTEXT) --timeout=90s
	kubectl rollout status deployment/htpasswd -n $(AUTH_NS) --context $(KUBE_CONTEXT) --timeout=120s
	@if ! kubectl get secret $(AUTH_SECRET) -n $(AUTH_NS) --context $(KUBE_CONTEXT) >/dev/null 2>&1; then \
		u="$(AUTH_USER)"; \
		[ -n "$$u" ] || u="$(AUTH_DEFAULT_USER)"; \
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
	echo "Browser: https://$(INGRESS_HOST)/"; \
	echo "curl:    curl -u '$(AUTH_USER):PASSWORD' https://$(INGRESS_HOST)/<prefix>"

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

# ---------------------------------------------------------------------------
# Shared services ([services.*] in config.toml)
# ---------------------------------------------------------------------------
.PHONY: services services-down services-info services-ns
services:
	@if [ -z "$(strip $(SERVICES_ENABLED))" ]; then \
		echo "No shared services enabled in config.toml ([services.*] enabled = true)"; \
	else \
		for s in $(SERVICES_ENABLED); do $(MAKE) $$s || exit 1; done; \
		$(MAKE) services-info; \
	fi

services-ns:
	@$(RENDER) $(SERVICES_DIR)/namespace.yaml | kubectl apply -f - --context $(KUBE_CONTEXT) >/dev/null

# Removes workloads but keeps PVCs and Secrets; delete the namespace to wipe data.
services-down:
	@for s in $(SERVICES); do $(MAKE) $$s-down; done
	@echo "Data kept: $(SVC_KUBECTL) get pvc,secret   (wipe: kubectl delete ns $(SERVICES_NS) --context $(KUBE_CONTEXT))"

services-info:
	@echo "========== Shared services ($(SERVICES_NS)) =========="
	@secret() { $(SVC_KUBECTL) get secret "$$1" -o "jsonpath={.data.$$2}" 2>/dev/null | base64 -d; }; \
	ns=$(SERVICES_NS); \
	if $(SVC_KUBECTL) get statefulset postgres >/dev/null 2>&1; then \
		echo "postgres  postgresql://$(POSTGRES_USER):$$(secret postgres password)@postgres.$$ns.svc.cluster.local:5432/$(POSTGRES_DB)"; \
		echo "          host: make postgres-forward -> 127.0.0.1:$(POSTGRES_LOCAL_PORT)"; \
	fi; \
	if $(SVC_KUBECTL) get statefulset redis >/dev/null 2>&1; then \
		echo "redis     redis://:$$(secret redis password)@redis.$$ns.svc.cluster.local:6379/0"; \
		echo "          host: make redis-forward -> 127.0.0.1:$(REDIS_LOCAL_PORT)"; \
	fi; \
	if $(SVC_KUBECTL) get statefulset nats >/dev/null 2>&1; then \
		echo "nats      nats://$$(secret nats token)@nats.$$ns.svc.cluster.local:4222"; \
		echo "          host: make nats-forward -> 127.0.0.1:$(NATS_LOCAL_PORT) (monitor :$(NATS_MONITOR_LOCAL_PORT))"; \
	fi; \
	if $(SVC_KUBECTL) get statefulset openbao >/dev/null 2>&1 || $(SVC_KUBECTL) get deployment openbao >/dev/null 2>&1; then \
		echo "openbao   http://openbao.$$ns.svc.cluster.local:8200  (mode: $(OPENBAO_MODE); root token: make openbao-token)"; \
		echo "          host: make openbao-forward -> http://127.0.0.1:$(OPENBAO_LOCAL_PORT)/ui"; \
	fi
	@echo "======================================================"

.PHONY: postgres postgres-down postgres-forward postgres-psql
postgres: services-ns
	@$(ENSURE_SECRET) $(KUBE_CONTEXT) $(SERVICES_NS) postgres password "$(POSTGRES_PASSWORD_CFG)"
	@$(RENDER) $(SERVICES_DIR)/postgres.yaml | kubectl apply -f - --context $(KUBE_CONTEXT)
	$(SVC_KUBECTL) rollout status statefulset/postgres --timeout=180s
	@for db in $(POSTGRES_DATABASES); do \
		if ! $(SVC_KUBECTL) exec postgres-0 -c postgres -- psql -U "$(POSTGRES_USER)" -d "$(POSTGRES_DB)" -tAc \
			"SELECT 1 FROM pg_database WHERE datname = '$$db'" | grep -q 1; then \
			$(SVC_KUBECTL) exec postgres-0 -c postgres -- createdb -U "$(POSTGRES_USER)" "$$db" && echo "Created database $$db"; \
		fi; \
	done

postgres-down:
	@$(RENDER) $(SERVICES_DIR)/postgres.yaml | kubectl delete -f - --context $(KUBE_CONTEXT) --ignore-not-found

postgres-forward:
	$(SVC_KUBECTL) port-forward svc/postgres $(POSTGRES_LOCAL_PORT):5432

postgres-psql:
	$(SVC_KUBECTL) exec -it postgres-0 -c postgres -- psql -U "$(POSTGRES_USER)" -d "$(POSTGRES_DB)"

.PHONY: redis redis-down redis-forward redis-cli
redis: services-ns
	@$(ENSURE_SECRET) $(KUBE_CONTEXT) $(SERVICES_NS) redis password "$(REDIS_PASSWORD_CFG)"
	@$(RENDER) $(SERVICES_DIR)/redis.yaml | kubectl apply -f - --context $(KUBE_CONTEXT)
	$(SVC_KUBECTL) rollout status statefulset/redis --timeout=180s

redis-down:
	@$(RENDER) $(SERVICES_DIR)/redis.yaml | kubectl delete -f - --context $(KUBE_CONTEXT) --ignore-not-found

redis-forward:
	$(SVC_KUBECTL) port-forward svc/redis $(REDIS_LOCAL_PORT):6379

redis-cli:
	$(SVC_KUBECTL) exec -it redis-0 -c redis -- sh -c 'REDISCLI_AUTH="$$REDIS_PASSWORD" exec redis-cli'

.PHONY: nats nats-down nats-forward
nats: services-ns
	@$(ENSURE_SECRET) $(KUBE_CONTEXT) $(SERVICES_NS) nats token "$(NATS_TOKEN_CFG)"
	@$(RENDER) $(SERVICES_DIR)/nats.yaml | kubectl apply -f - --context $(KUBE_CONTEXT)
	@# nats.conf lives in a ConfigMap: restart so config changes take effect.
	$(SVC_KUBECTL) rollout restart statefulset/nats
	$(SVC_KUBECTL) rollout status statefulset/nats --timeout=180s

nats-down:
	@$(RENDER) $(SERVICES_DIR)/nats.yaml | kubectl delete -f - --context $(KUBE_CONTEXT) --ignore-not-found

nats-forward:
	$(SVC_KUBECTL) port-forward svc/nats $(NATS_LOCAL_PORT):4222 $(NATS_MONITOR_LOCAL_PORT):8222

.PHONY: openbao openbao-down openbao-init openbao-unseal openbao-status openbao-token openbao-forward
openbao: services-ns
ifeq ($(OPENBAO_MODE),dev)
	@$(SVC_KUBECTL) delete statefulset openbao --ignore-not-found >/dev/null
	@$(ENSURE_SECRET) $(KUBE_CONTEXT) $(SERVICES_NS) openbao root-token "$(OPENBAO_DEV_ROOT_TOKEN_CFG)"
	@$(RENDER) $(SERVICES_DIR)/openbao-dev.yaml | kubectl apply -f - --context $(KUBE_CONTEXT)
	$(SVC_KUBECTL) rollout status deployment/openbao --timeout=180s
else
	@$(SVC_KUBECTL) delete deployment openbao --ignore-not-found >/dev/null
	@$(RENDER) $(SERVICES_DIR)/openbao-standalone.yaml | kubectl apply -f - --context $(KUBE_CONTEXT)
	@$(MAKE) openbao-init
	$(SVC_KUBECTL) wait --for=condition=Ready pod/openbao-0 --timeout=120s
endif

openbao-down:
	@$(SVC_KUBECTL) delete deployment,statefulset openbao --ignore-not-found
	@$(SVC_KUBECTL) delete service openbao --ignore-not-found
	@$(SVC_KUBECTL) delete configmap openbao-config --ignore-not-found

# Standalone mode: first run initialises (1 key share) and saves keys; later runs only unseal.
openbao-init:
	@$(OPENBAO_SCRIPT) init $(KUBE_CONTEXT) $(SERVICES_NS) $(OPENBAO_KEYS_DIR)

# Needed after every OpenBao pod restart (standalone mode).
openbao-unseal:
	@$(OPENBAO_SCRIPT) unseal $(KUBE_CONTEXT) $(SERVICES_NS) $(OPENBAO_KEYS_DIR)

openbao-status:
	@$(SVC_KUBECTL) exec deploy/openbao -c openbao -- bao status 2>/dev/null \
		|| $(SVC_KUBECTL) exec openbao-0 -c openbao -- bao status || true

openbao-token:
ifeq ($(OPENBAO_MODE),dev)
	@$(SVC_KUBECTL) get secret openbao -o jsonpath='{.data.root-token}' | base64 -d; echo
else
	@$(OPENBAO_SCRIPT) token $(KUBE_CONTEXT) $(SERVICES_NS) $(OPENBAO_KEYS_DIR)
endif

openbao-forward:
	$(SVC_KUBECTL) port-forward svc/openbao $(OPENBAO_LOCAL_PORT):8200

.PHONY: down
down:
	kind delete cluster --name $(KIND_CLUSTER)
