GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
NC := \033[0m

CLUSTER_NAME := crossplane-local
CROSSPLANE_NAMESPACE := crossplane-system
REGISTRY_NAMESPACE := default
MANIFEST_DIR := manifests
CERT_NAME := oci-registry-tls
CONFIG_MAP_NAME := distribution-ca
CHART_NAME := crossplane
CHART_REPO_NAME := crossplane-stable
CHART_REPO_URL := https://charts.crossplane.io/stable
IMAGE_TAG := oci-registry.default.svc.cluster.local/crossplane-contrib/function-kcl:v0.11.4
LOCAL_IMAGE := localhost:5000/crossplane-contrib/function-kcl:v0.11.4

REQUIRED_TOOLS := kind kubectl helm openssl docker skopeo

.PHONY: all check-tools install create-cluster create-namespace generate-cert install-crossplane install-oci-registry build-image push-image deploy-function cleanup

all: check-tools create-cluster create-namespace generate-cert install-crossplane install-oci-registry build-image push-image deploy-function
	@echo "$(GREEN)✅ Setup complete!$(NC)"

check-tools:
	@echo "$(YELLOW)🔍 Checking required tools...$(NC)"
	@for tool in $(REQUIRED_TOOLS); do \
		if ! command -v $$tool > /dev/null; then \
			echo "$(RED)❌ Error: $$tool is not installed.$(NC)"; exit 1; \
		fi; \
	done
	@echo "$(GREEN)✅ All tools installed.$(NC)"

install:
	@echo "$(YELLOW)🔧 Installing required tools with Homebrew...$(NC)"
	@for tool in $(REQUIRED_TOOLS); do \
		if ! command -v $$tool > /dev/null; then \
			echo "$(YELLOW)📦 Installing $$tool...$(NC)"; \
			brew install $$tool || { echo "$(RED)❌ Failed to install $$tool$(NC)"; exit 1; }; \
		else \
			echo "$(GREEN)✅ $$tool already installed.$(NC)"; \
		fi; \
	done
	@echo "$(GREEN)✅ All required tools are installed.$(NC)"

create-cluster:
	@echo "$(YELLOW)🔁 (Re)creating kind cluster: $(CLUSTER_NAME)$(NC)"
	-kind delete cluster --name $(CLUSTER_NAME)
	kind create cluster --name $(CLUSTER_NAME)

create-namespace:
	@echo "$(YELLOW)📦 Creating namespace: $(CROSSPLANE_NAMESPACE)$(NC)"
	kubectl create namespace $(CROSSPLANE_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

generate-cert:
	@echo "$(YELLOW)🔐 Generating TLS certificate$(NC)"
	@openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
		-keyout tls.key -out tls.crt \
		-config openssl-san.cnf -extensions req_ext >/dev/null 2>&1 || { echo "$(RED)❌ Failed to generate certificate$(NC)"; exit 1; }
	@echo "$(YELLOW)📦 Creating Kubernetes secrets and configmaps$(NC)"
	@kubectl create secret tls $(CERT_NAME) --cert=tls.crt --key=tls.key -n $(REGISTRY_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create configmap $(CONFIG_MAP_NAME) --from-file=tls.crt -n $(CROSSPLANE_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@rm -f tls.key tls.crt

install-crossplane:
	@echo "$(YELLOW)📦 Installing Crossplane via Helm$(NC)"
	@helm repo add $(CHART_REPO_NAME) $(CHART_REPO_URL) >/dev/null 2>&1 || true
	@helm repo update >/dev/null || { echo "$(RED)❌ helm repo update failed$(NC)"; exit 1; }
	@helm upgrade --install -f override.yaml $(CHART_NAME) \
		--namespace $(CROSSPLANE_NAMESPACE) $(CHART_REPO_NAME)/$(CHART_NAME)

install-oci-registry:
	@echo "$(YELLOW)📦 Installing OCI Registry$(NC)"
	kubectl apply -f distribution.yaml
	kubectl rollout status deployment/oci-registry --timeout=60s -n $(REGISTRY_NAMESPACE)

build-image:
	@echo "$(YELLOW)🐳 Building Docker image: $(IMAGE_TAG)$(NC)"
	docker build -t $(IMAGE_TAG) .

push-image:
	@echo "$(YELLOW)📦 Pushing image to kind and OCI registry$(NC)"
	kind load docker-image $(IMAGE_TAG) --name $(CLUSTER_NAME)
	@echo "$(YELLOW)📡 Port-forwarding to OCI registry$(NC)"
	@{ \
		kubectl port-forward svc/oci-registry 5000:443 -n $(REGISTRY_NAMESPACE) >/dev/null 2>&1 & \
		echo $$! > port_forward.pid; \
	}
	@echo "$(YELLOW)⏳ Waiting for registry to be reachable on port 5000...$(NC)"
	@until nc -z localhost 5000; do sleep 1; done
	@echo "$(YELLOW)📤 Copying image with skopeo$(NC)"
	@{ \
		skopeo copy --dest-tls-verify=false \
			docker-daemon:$(IMAGE_TAG) \
			docker://$(LOCAL_IMAGE) > /dev/null; \
	} || { echo "$(RED)❌ skopeo copy failed$(NC)"; exit 1; }
	@$(MAKE) cleanup

deploy-function:
	@echo "$(YELLOW)🚀 Deploying Crossplane Function$(NC)"
	@until kubectl get crd functions.pkg.crossplane.io >/dev/null 2>&1; do \
		echo "$(YELLOW)⏳ Waiting for Function CRD to be created...$(NC)"; \
		sleep 1; \
	done
	kubectl wait --for=condition=Established crd/functions.pkg.crossplane.io --timeout=60s
	kubectl apply -f function.yaml

delete-function:
	@echo "$(YELLOW)🗑️ Deleting Crossplane Function$(NC)"
	kubectl delete -f function.yaml

cleanup:
	@echo "$(YELLOW)🧹 Cleaning up port-forward$(NC)"
	@if [ -f port_forward.pid ]; then \
		PID=$$(cat port_forward.pid); \
		if [ -n "$$PID" ] && kill -0 $$PID 2>/dev/null; then \
			echo "$(YELLOW)🔪 Killing port-forward process $$PID$(NC)"; \
			kill $$PID; \
		else \
			echo "$(RED)⚠️ PID $$PID is not running or invalid$(NC)"; \
		fi; \
		rm -f port_forward.pid; \
	else \
		echo "$(YELLOW)ℹ️ No port_forward.pid file found$(NC)"; \
	fi

redeploy-function:
	@echo "$(YELLOW)🔄 Redeploying Crossplane Function$(NC)"
	@$(MAKE) build-image
	@$(MAKE) push-image
	@$(MAKE) delete-function
	@$(MAKE) deploy-function
	@echo "$(GREEN)✅ Redeployment complete!$(NC)"